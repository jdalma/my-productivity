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
