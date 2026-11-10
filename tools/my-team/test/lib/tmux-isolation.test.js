/**
 * Tests must never reach the user's tmux server (T51c): under a test runner, tmux-utils calls tmux only
 * when test/run-isolated.sh marked the run (MY_TEAM_TEST_TMUX) after naming a server of its own.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'child_process';
import { fileURLToPath } from 'url';

import { underTestWithoutIsolation } from '../../src/lib/tmux-utils.js';

test('every way of running a test file without the mark is caught; the mark or a normal run is not', () => {
    const file = ['node', '/r/test/x.test.js'];
    assert.equal(underTestWithoutIsolation({ NODE_TEST_CONTEXT: 'child-v8' }, ['node', '/r/x.js'], []), true, 'node --test');
    assert.equal(underTestWithoutIsolation({}, ['node', 'x.js'], ['--test', '--test-isolation=none']), true, 'in-process --test');
    assert.equal(underTestWithoutIsolation({}, file, []), true, 'node <file>.test.js');
    assert.equal(underTestWithoutIsolation({}, ['node', '/r/y.test.mjs'], []), true);
    assert.equal(underTestWithoutIsolation({ NODE_TEST_CONTEXT: 'child-v8', MY_TEAM_TEST_TMUX: 'my-team-test-1' }, file, []), false, 'run-isolated.sh');
    assert.equal(underTestWithoutIsolation({}, ['node', '/usr/local/bin/my-team', 'start'], []), false, 'the CLI itself');
});

test('a test process without the mark throws before any tmux runs', () => {
    const utils = fileURLToPath(new URL('../../src/lib/tmux-utils.js', import.meta.url));
    const { MY_TEAM_TEST_TMUX: _, ...env } = process.env;
    // -V touches no server, should the guard ever fail
    const script = `import { tmuxExec } from ${JSON.stringify(utils)}; try { tmuxExec(['-V']); console.log('RAN'); } catch (e) { console.log('BLOCKED ' + e.message); }`;
    // a child of `node --test`, as the runner marks one
    const r = spawnSync(process.execPath, ['--input-type=module', '-e', script],
        { env: { ...env, NODE_TEST_CONTEXT: 'child-v8' }, encoding: 'utf-8' });
    const out = r.stdout + r.stderr;
    assert.match(out, /BLOCKED my-team tests must not reach the real tmux server/, out);
});

test('with the mark, tmux-utils names the test server itself, so a test outliving its runner never finds the default one (M4)', async () => {
    const { tmuxSocketArgs } = await import('../../src/lib/tmux-utils.js');
    const cli = ['node', '/usr/local/bin/my-team'];
    assert.deepEqual(tmuxSocketArgs({ NODE_TEST_CONTEXT: 'child-v8', MY_TEAM_TEST_TMUX: 'my-team-test-7' }, cli, []), ['-L', 'my-team-test-7']);
    assert.deepEqual(tmuxSocketArgs({ MY_TEAM_TEST_TMUX: 'my-team-test-7' }, ['node', '/r/x.test.js'], []), ['-L', 'my-team-test-7']);
    assert.deepEqual(tmuxSocketArgs({}, cli, []), [], 'the CLI uses the server it is in');
    // a mark leaked out of a test run is ignored: the CLI still sees the user's server, its teams alive (R5)
    assert.deepEqual(tmuxSocketArgs({ MY_TEAM_TEST_TMUX: 'stray' }, cli, []), []);

    // the runner is gone: no wrapper on PATH, only the mark left. Every call shape still names the socket;
    // `ls` and `list-panes` on a named socket with no server only say so.
    const utils = fileURLToPath(new URL('../../src/lib/tmux-utils.js', import.meta.url));
    const name = `my-team-test-orphan-${process.pid}`;
    const script = `import { tmuxExec, tmuxShell, tmuxCmdAsync } from ${JSON.stringify(utils)};
        for (const call of [() => tmuxExec(['ls'], { stdio: 'pipe' }), () => tmuxShell('ls', { stdio: 'pipe' }),
                            () => tmuxCmdAsync(['list-panes', '-a', '-F', '#{pane_id}'])]) {
            try { await call(); console.log('NO-ERROR'); } catch (e) { console.log(String(e.stderr || e.message).trim()); }
        }`;
    const r = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
        env: { ...process.env, PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', MY_TEAM_TEST_TMUX: name, NODE_TEST_CONTEXT: 'child-v8' },
        encoding: 'utf-8',
    });
    const lines = r.stdout.trim().split('\n');
    assert.equal(lines.length, 3, r.stdout + r.stderr);
    for (const l of lines) assert.match(l, new RegExp(`(no server running on|error connecting to) \\S*/${name}`), l);
});
