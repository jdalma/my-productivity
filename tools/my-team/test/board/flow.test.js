/**
 * One task through the board's write commands, end to end (T63e; docs/board.md, One cycle): the real CLI, a
 * scratch git repository, a temporary state base, and panes on the test run's own tmux server (run-isolated.sh
 * names it; tmux-utils adds -L). add → take → land → verdict(changes) → take → land → verdict(approve), each
 * by the worker MY_TEAM_WORKER names. Then the mailbox notices (one line, no state in them) and the events.
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

// A tmux server of this file's own, under the run's: other test files type into fixed pane ids (%0, %9 …) on
// the run's server, and one of them can be a pane here. The CLI runs below inherit it.
if (process.env.MY_TEAM_TEST_TMUX) {
    const own = `${process.env.MY_TEAM_TEST_TMUX}-flow`;
    process.env.MY_TEAM_TEST_TMUX = own;
    test.after(() => {
        try { tmuxExec(['kill-server'], { stdio: 'pipe' }); } catch { /* none left */ }
        rmSync(`/tmp/tmux-${process.getuid()}/${own}`, { force: true });
    });
}
const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const TEAM = 'flow-team';
/**
 * A worker pane stand-in: it records each line typed into it and erases the echoed line, as a CLI clears its
 * input line on submit, so the trigger counts as submitted at the first Enter. (Clearing the whole screen
 * would push the line into tmux's history, where the submit check still finds it.)
 */
const sink = (log) => `while IFS= read -r l; do printf '%s\\n' "$l" >> '${log}'; printf '\\033[1A\\033[2K'; done`;

function scratchRepo(t) {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'mt-flow-repo-')));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { encoding: 'utf-8' }).trim();
    git('init', '-q', '-b', 'main');
    const commit = (name) => { writeFileSync(join(dir, name), name); git('add', name); git('commit', '-q', '-m', name); return git('rev-parse', 'HEAD'); };
    return { dir, commit };
}

function scratchTeam(t, repoDir) {
    const base = realpathSync(mkdtempSync(join(tmpdir(), 'mt-flow-state-')));
    t.after(() => rmSync(base, { recursive: true, force: true }));
    const session = `my-team-flow-${process.pid}`;
    const typedLog = join(base, 'typed.log');
    tmuxExec(['new-session', '-d', '-s', session, sink(`${typedLog}.pm`)], { stdio: 'pipe' });
    t.after(() => { try { tmuxExec(['kill-session', '-t', session], { stdio: 'pipe' }); } catch { /* gone */ } });
    const first = tmuxExec(['display-message', '-p', '-t', session, '#{pane_id}'], { stdio: 'pipe' }).trim();
    const more = ['core', 'rv'].map((w) => tmuxExec(['split-window', '-d', '-P', '-F', '#{pane_id}', '-t', session, sink(`${typedLog}.${w}`)], { stdio: 'pipe' }).trim());
    const panes = { pm: first, core: more[0], rv: more[1] };
    // as start does: a notice is typed only into a pane tagged with its worker's name (T63e1)
    for (const [name, id] of Object.entries(panes)) tmuxExec(['set-option', '-p', '-t', id, '@worker_name', name], { stdio: 'pipe' });
    const root = join(base, TEAM);
    mkdirSync(root, { recursive: true });
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: TEAM, state_root: root, session_name: `${session}:0`, board: { store: 'sqlite' },
        workers: [
            { name: 'pm', role: 'orchestrator', agent_type: 'claude', pane_id: panes.pm, cwd: base },
            { name: 'core', role: 'worker', agent_type: 'claude', pane_id: panes.core, cwd: join(repoDir) },
            { name: 'rv', role: 'worker', agent_type: 'claude', pane_id: panes.rv, cwd: base },
        ],
    }));
    return { base, root, panes, typed: (w) => (existsSync(`${typedLog}.${w}`) ? readFileSync(`${typedLog}.${w}`, 'utf-8') : '') };
}

function as(base, worker, command, input) {
    const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base, MY_TEAM_WORKER: `${TEAM}/${worker}` };
    for (const k of ['OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
    const r = spawnSync(process.execPath, [MY_TEAM, 'api', command, '--input', JSON.stringify({ team_name: TEAM, ...input }), '--json'], { env, encoding: 'utf-8' });
    const json = JSON.parse(r.stdout);
    assert.equal(r.status, 0, `${worker} ${command}: ${r.stdout}${r.stderr}`);
    return json;
}

const spool = (root, worker) => {
    const dir = join(root, 'incoming-spool', worker);
    return existsSync(dir) ? readdirSync(dir).map((f) => JSON.parse(readFileSync(join(dir, f), 'utf-8'))) : [];
};

test('one task from add to approve through the CLI: notices to the right workers, one board event per change', { skip: hasSqlite ? false : 'node:sqlite needs Node >= 22.13' }, async (t) => {
    const repo = scratchRepo(t);
    const base0 = repo.commit('base');
    const { base, root, typed } = scratchTeam(t, repo.dir);
    const work = { ticket: '/t/T1.md', constraints: 'tmux -L only' };

    as(base, 'pm', 'board-add', { id: 'T1', title: 'first', assignee: 'core', reviewer: 'rv', base: base0, ...work });
    as(base, 'core', 'board-take', { id: 'T1' });
    const c1 = repo.commit('one');
    const l1 = as(base, 'core', 'board-land', {
        id: 'T1', commit: c1, check: { cmd: 'npm test', result: '1/1' }, focus: ['the change'], closes: [],
        report: '/r/T1.md', review_report: '/r/R1.md',
    });
    assert.deepEqual([l1.landing.repo, l1.landing.commits, l1.task.state], [repo.dir, [c1], 'review']);
    as(base, 'rv', 'board-verdict', {
        landing: 'T1#1', verdict: 'changes', verified_commit: c1, report: '/r/R1.md', rerun: { cmd: 'npm test', result: '1/1' },
        findings: [{ code: 'M1', severity: 'must', summary: 'fix it', repro: 'npm test' }],
    });
    as(base, 'core', 'board-take', { id: 'T1' });
    const c2 = repo.commit('two');
    const l2 = as(base, 'core', 'board-land', {
        id: 'T1', commit: c2, check: { cmd: 'npm test', result: '2/2' }, focus: ['M1'], closes: ['R1 M1'],
        report: '/r/T1.md', review_report: '/r/R1.md', base: c1,
    });
    assert.deepEqual(l2.fixed, ['R1 M1']);
    const done = as(base, 'rv', 'board-verdict', {
        landing: 'T1#2', verdict: 'approve', verified_commit: c2, report: '/r/R1.md', rerun: { cmd: 'npm test', result: '2/2' }, findings: [],
    });
    assert.equal(done.task.state, 'done');

    const notices = { pm: spool(root, 'pm'), core: spool(root, 'core'), rv: spool(root, 'rv') };
    assert.deepEqual(Object.fromEntries(Object.entries(notices).map(([w, n]) => [w, n.length])), { pm: 2, core: 3, rv: 2 }, 'R70 L2: 7 a cycle; land goes to the reviewer only');
    for (const n of Object.values(notices).flat()) {
        assert.match(n.body, /^\[board\] T1(#\d)? (add|land)$|^\[board\] R1a? verdict$/, n.body);
        assert.equal(n.expects_reply, false);
    }
    assert.deepEqual(notices.core.map((n) => n.from_worker).sort(), ['pm', 'rv', 'rv']);

    const events = readFileSync(join(root, 'events.jsonl'), 'utf-8').trim().split('\n').map((l) => JSON.parse(l)).filter((e) => e.type === 'board');
    assert.deepEqual(events.map((e) => [e.worker, e.action, e.ref]), [
        ['pm', 'add', 'T1'], ['core', 'take', 'T1'], ['core', 'land', 'T1#1'], ['rv', 'verdict', 'R1'],
        ['core', 'take', 'T1'], ['core', 'land', 'T1#2'], ['rv', 'verdict', 'R1a'],
    ]);
    assert.deepEqual(events.map((e) => e.log_seq), [1, 2, 3, 4, 5, 6, 7]);
    assert.deepEqual([events[6].state_from, events[6].state_to], ['review', 'done']);

    // sendToWorker presses Enter twice per round, so empty lines come in between
    assert.deepEqual(typed('core').split('\n').filter(Boolean), ['new-message:pm', 'new-message:rv', 'new-message:rv'], 'each notice typed one trigger into the pane');
});

test('write commands refuse what the worker may not do, as JSON errors', { skip: hasSqlite ? false : 'node:sqlite needs Node >= 22.13' }, async (t) => {
    const repo = scratchRepo(t);
    const base0 = repo.commit('base');
    const { base, root } = scratchTeam(t, repo.dir);
    const run = (worker, command, input) => {
        const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base, MY_TEAM_WORKER: `${TEAM}/${worker}` };
        for (const k of ['OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
        const r = spawnSync(process.execPath, [MY_TEAM, 'api', command, '--input', JSON.stringify({ team_name: TEAM, ...input }), '--json'], { env, encoding: 'utf-8' });
        return { code: r.status, json: JSON.parse(r.stdout) };
    };
    assert.deepEqual(run('core', 'board-add', { title: 'x' }).json.code, 'forbidden');
    as(base, 'pm', 'board-add', { id: 'T1', title: 'first', assignee: 'core', reviewer: 'rv', base: base0, ticket: '/t', constraints: 'c' });
    as(base, 'core', 'board-take', { id: 'T1' });
    const missing = run('core', 'board-land', { id: 'T1', commit: 'f'.repeat(40), check: { cmd: 'x', result: 'y' }, focus: ['f'], closes: [], report: '/r', review_report: '/R' });
    assert.deepEqual([missing.code, missing.json.code], [1, 'invalid']);
    assert.match(missing.json.message, /no commit/);
    const posing = run('core', 'board-take', { id: 'T1', by: 'rv' });
    assert.deepEqual([posing.code, posing.json.code], [1, 'forbidden']);
    assert.equal(run('core', 'board-note', { id: 'T1', body: 'n', to: ['pm'] }).code, 0);
    assert.equal(run('pm', 'board-announce', { body: 'a' }).code, 0);
    assert.equal(spool(root, 'rv').length, 1, 'the announcement');
});
