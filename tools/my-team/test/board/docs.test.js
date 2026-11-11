/**
 * docs/board.md's cycle runs as written (T63g): every line between the example markers, through the real CLI,
 * against a scratch git repository and a temporary state base. $BASE, $C1, $C2 become that repository's
 * commits. Notices go to panes on a tmux server of this file's own, which has none, so nothing is typed anywhere.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { tmuxExec } from '../../src/lib/tmux-utils.js';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));
const DOC = fileURLToPath(new URL('../../docs/board.md', import.meta.url));
const hasSqlite = await import('node:sqlite').then(() => true, () => false);

if (process.env.MY_TEAM_TEST_TMUX) {
    const own = `${process.env.MY_TEAM_TEST_TMUX}-docs`;
    process.env.MY_TEAM_TEST_TMUX = own;
    test.after(() => {
        try { tmuxExec(['kill-server'], { stdio: 'pipe' }); } catch { /* never started */ }
        rmSync(`/tmp/tmux-${process.getuid()}/${own}`, { force: true });
    });
}

/** The example lines: [worker, command, input text]. */
function exampleLines() {
    const doc = readFileSync(DOC, 'utf-8');
    const block = doc.slice(doc.indexOf('<!-- example:start -->'), doc.indexOf('<!-- example:end -->'));
    return block.split('\n').filter((l) => l.startsWith('MY_TEAM_WORKER=')).map((l) => {
        const m = /^MY_TEAM_WORKER=demo\/(\S+) my-team api (board-[a-z-]+) --input '([^']*)' --json$/.exec(l);
        assert.ok(m, `an example line this test can run as written: ${l}`);
        return m.slice(1);
    });
}

test('the cycle in docs/board.md runs as written and ends where the doc says', { skip: hasSqlite ? false : 'node:sqlite needs Node >= 22.13' }, (t) => {
    const lines = exampleLines();
    assert.equal(lines.length, 10);

    const repo = realpathSync(mkdtempSync(join(tmpdir(), 'mt-docs-repo-')));
    const base = realpathSync(mkdtempSync(join(tmpdir(), 'mt-docs-state-')));
    t.after(() => { rmSync(repo, { recursive: true, force: true }); rmSync(base, { recursive: true, force: true }); });
    const git = (...args) => execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { encoding: 'utf-8' }).trim();
    git('init', '-q', '-b', 'main');
    const commits = {};
    for (const name of ['BASE', 'C1', 'C2']) { writeFileSync(join(repo, name), name); git('add', name); git('commit', '-q', '-m', name); commits[name] = git('rev-parse', 'HEAD'); }

    const root = join(base, 'demo');
    mkdirSync(root);
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: 'demo', state_root: root, session_name: 'none:0', board: { store: 'sqlite' },
        workers: ['pm', 'dev', 'rv'].map((name, i) => ({ name, role: i ? 'worker' : 'orchestrator', agent_type: 'claude', pane_id: `%${900 + i}`, cwd: name === 'dev' ? repo : base })),
    }));

    let last;
    for (const [worker, command, input] of lines) {
        const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base, MY_TEAM_WORKER: `demo/${worker}` };
        for (const k of ['OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
        const text = input.replace(/\$(BASE|C1|C2)\b/g, (_, k) => commits[k]);
        const r = spawnSync(process.execPath, [MY_TEAM, 'api', command, '--input', text, '--json'], { env, encoding: 'utf-8' });
        assert.equal(r.status, 0, `${worker} ${command}: ${r.stdout}${r.stderr}`);
        last = JSON.parse(r.stdout);
    }

    assert.equal(last.tasks[0].state, 'done');
    assert.deepEqual(last.landings.map((l) => l.id), ['T1#1', 'T1#2']);
    assert.deepEqual(last.verdicts.map((v) => v.id).sort(), ['R1', 'R1a']);
    assert.deepEqual(last.findings.map((f) => [f.id, f.state, f.fixed_in]), [['R1 M1', 'fixed', 'T1#2']]);
    const notices = (w) => (existsSync(join(root, 'incoming-spool', w)) ? readdirSync(join(root, 'incoming-spool', w)).length : 0);
    assert.deepEqual({ pm: notices('pm'), dev: notices('dev'), rv: notices('rv') }, { pm: 2, dev: 3, rv: 2 });
});
