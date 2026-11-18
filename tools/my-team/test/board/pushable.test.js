/**
 * `my-team api board-pushable` (T63f): whether every commit a push would send has an approved review on the
 * team board, or is an ancestor of the repository's baseline (commits reviewed before the board, or the
 * user's own). Through the real CLI, on a scratch repository and a temporary state base; no tmux.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { createBoard } from '../../src/board/core/service.js';
import { gitRange } from '../../src/board/git.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));
const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const needsSqlite = hasSqlite ? {} : { skip: 'node:sqlite needs Node >= 22.13' };
const ROSTER = [{ name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' }, { name: 'rv', role: 'worker' }];

/** A repository with commits base, a1, a2 (approved together), p1 (in review), x1 (not on the board). */
async function world(t) {
    const repo = realpathSync(mkdtempSync(join(tmpdir(), 'mt-push-repo-')));
    const base = realpathSync(mkdtempSync(join(tmpdir(), 'mt-push-state-')));
    t.after(() => { rmSync(repo, { recursive: true, force: true }); rmSync(base, { recursive: true, force: true }); });
    const git = (...args) => execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { encoding: 'utf-8' }).trim();
    git('init', '-q', '-b', 'main');
    const commit = (name) => { writeFileSync(join(repo, name), name); git('add', name); git('commit', '-q', '-m', `subject of ${name}`); return git('rev-parse', 'HEAD'); };
    const c = { base: commit('base') };
    for (const name of ['a1', 'a2', 'p1', 'x1']) c[name] = commit(name);

    const root = join(base, 'pt');
    mkdirSync(root);
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: 'pt', state_root: root, session_name: 'none:0', board: { store: 'sqlite' },
        workers: ROSTER.map((w) => ({ ...w, agent_type: 'claude', pane_id: '%999', cwd: repo })),
    }));
    const store = createSqliteStore(join(root, 'board.db'));
    await store.open();
    let tick = 0;
    const now = () => new Date(Date.UTC(2026, 10, 11, 0, 0, tick++)).toISOString();
    const as = (actor) => createBoard({ store, roster: () => ROSTER, actor, now, git: gitRange });
    const land = (id, commit, extra = {}) => as('core').land({ id, repo, commit, check: { cmd: 'npm test', result: 'ok' }, focus: ['f'], closes: [], report: '/r', ...extra });
    await as('pm').add({ id: 'T1', title: 'approved', assignee: 'core', reviewer: 'rv', base: c.base });
    await as('core').take({ id: 'T1' });
    await land('T1', c.a2);
    await as('rv').verdict({ landing: 'T1#1', verdict: 'approve', verified_commit: c.a2, report: '/R', rerun: { cmd: 'x', result: 'y' }, findings: [] });
    await as('pm').add({ id: 'T2', title: 'in review', assignee: 'core', reviewer: 'rv', base: c.a2 });
    await as('core').take({ id: 'T2' });
    await land('T2', c.p1);
    await store.close();
    return { repo, base, c, git, commit };
}

function pushable(w, input) {
    const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: w.base };
    for (const k of ['MY_TEAM_WORKER', 'OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
    const r = spawnSync(process.execPath, [MY_TEAM, 'api', 'board-pushable', '--input', JSON.stringify({ team_name: 'pt', repo: w.repo, ...input }), '--json'], { env, encoding: 'utf-8' });
    return { code: r.status, json: JSON.parse(r.stdout || 'null'), err: r.stderr };
}

test('(a) a range of approved commits only is pushable', needsSqlite, async (t) => {
    const w = await world(t);
    const r = pushable(w, { commit: w.c.a2, upstream: w.c.base });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual([r.json.ok, r.json.covered, r.json.uncovered], [true, 2, []]);
});

test('(b) a commit in review or not on the board is not, and each is named with its subject', needsSqlite, async (t) => {
    const w = await world(t);
    const r = pushable(w, { commit: w.c.x1, upstream: w.c.base });
    assert.equal(r.json.ok, false);
    assert.equal(r.json.covered, 2);
    assert.deepEqual(r.json.uncovered, [
        { commit: w.c.x1, short: w.c.x1.slice(0, 7), subject: 'subject of x1' },
        { commit: w.c.p1, short: w.c.p1.slice(0, 7), subject: 'subject of p1' },
    ]);
});

test('(c) a commit added after the approval is not covered by it', needsSqlite, async (t) => {
    const w = await world(t);
    w.git('checkout', '-q', '-b', 'later', w.c.a2);
    const late = w.commit('late');
    const r = pushable(w, { commit: late, upstream: w.c.base });
    assert.deepEqual([r.json.ok, r.json.uncovered.map((u) => u.commit)], [false, [late]]);
});

test('(d) the baseline covers its ancestors; commits after it, off the board, stay uncovered', needsSqlite, async (t) => {
    const w = await world(t);
    const r = pushable(w, { commit: w.c.x1, upstream: w.c.base, baseline: w.c.p1 });
    assert.deepEqual([r.json.ok, r.json.covered, r.json.uncovered.map((u) => u.commit)], [false, 3, [w.c.x1]]);
    assert.equal(pushable(w, { commit: w.c.x1, upstream: w.c.base, baseline: w.c.x1 }).json.ok, true);
});

test('a new branch: everything not on the remote\'s refs is checked', needsSqlite, async (t) => {
    const w = await world(t);
    const bare = realpathSync(mkdtempSync(join(tmpdir(), 'mt-push-bare-')));
    t.after(() => rmSync(bare, { recursive: true, force: true }));
    execFileSync('git', ['init', '-q', '--bare', bare]);
    w.git('remote', 'add', 'origin', bare);
    w.git('push', '-q', 'origin', `${w.c.base}:refs/heads/main`);
    w.git('fetch', '-q', 'origin');
    const r = pushable(w, { commit: w.c.a2, remote: 'origin' });
    assert.deepEqual([r.json.ok, r.json.covered], [true, 2]);
    assert.deepEqual(pushable(w, { commit: w.c.p1, remote: 'origin' }).json.uncovered.map((u) => u.commit), [w.c.p1]);
});

test('an approval counts only in its own repository', needsSqlite, async (t) => {
    const w = await world(t);
    const clone = realpathSync(mkdtempSync(join(tmpdir(), 'mt-push-clone-')));
    t.after(() => rmSync(clone, { recursive: true, force: true }));
    execFileSync('git', ['clone', '-q', w.repo, join(clone, 'c')]);
    const r = pushable({ ...w, repo: join(clone, 'c') }, { commit: w.c.a2, upstream: w.c.base });
    assert.deepEqual([r.json.ok, r.json.uncovered.length], [false, 2]);
});

/**
 * A worktree of the repository (T113): side commits s1, s2 landed from it, recorded with the worktree's top level as
 * their repo, and approved. The repo of every landing already on a board is recorded the same way.
 */
async function worktreeWorld(t) {
    const w = await world(t);
    const wt = join(realpathSync(mkdtempSync(join(tmpdir(), 'mt-push-wt-'))), 'side');
    t.after(() => rmSync(join(wt, '..'), { recursive: true, force: true }));
    w.git('worktree', 'add', '-q', '-b', 'side', wt, w.c.a2);
    const gitWt = (...args) => execFileSync('git', ['-C', wt, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { encoding: 'utf-8' }).trim();
    const commit = (name) => { writeFileSync(join(wt, name), name); gitWt('add', name); gitWt('commit', '-q', '-m', `subject of ${name}`); return gitWt('rev-parse', 'HEAD'); };
    const s1 = commit('s1'), s2 = commit('s2');
    const store = createSqliteStore(join(w.base, 'pt', 'board.db'));
    await store.open();
    let tick = 100;
    const now = () => new Date(Date.UTC(2026, 10, 11, 0, 0, tick++)).toISOString();
    const as = (actor) => createBoard({ store, roster: () => ROSTER, actor, now, git: gitRange });
    await as('pm').add({ id: 'T3', title: 'from a worktree', assignee: 'core', reviewer: 'rv', base: w.c.a2 });
    await as('core').take({ id: 'T3' });
    await as('core').land({ id: 'T3', repo: wt, commit: s2, check: { cmd: 'npm test', result: 'ok' }, focus: ['f'], closes: [], report: '/r' });
    await as('rv').verdict({ landing: 'T3#1', verdict: 'approve', verified_commit: s2, report: '/R', rerun: { cmd: 'x', result: 'y' }, findings: [] });
    assert.equal((await store.get('landing', 'T3#1')).repo, wt, 'the landing keeps the worktree path it was landed from');
    await store.close();
    return { ...w, wt, gitWt, s1, s2 };
}

test('T113 (a, d): a commit approved in a worktree is covered from the main working folder and from the worktree', needsSqlite, async (t) => {
    const w = await worktreeWorld(t);
    for (const repo of [w.repo, w.wt]) {
        const r = pushable({ ...w, repo }, { commit: w.s2, upstream: w.c.a2 });
        assert.equal(r.code, 0, r.err);
        assert.deepEqual([r.json.ok, r.json.covered, r.json.uncovered], [true, 2, []], repo);
    }
    const main = pushable(w, { commit: w.c.a2, upstream: w.c.base });
    assert.deepEqual([main.json.ok, main.json.covered], [true, 2], 'approvals landed from the main folder still count from it');
    const fromWt = pushable({ ...w, repo: w.wt }, { commit: w.c.a2, upstream: w.c.base });
    assert.deepEqual([fromWt.json.ok, fromWt.json.covered], [true, 2], 'and from its worktree');
});

test('T113 (b): another clone with the same commits is another repository', needsSqlite, async (t) => {
    const w = await worktreeWorld(t);
    const clone = join(realpathSync(mkdtempSync(join(tmpdir(), 'mt-push-clone-'))), 'c');
    t.after(() => rmSync(join(clone, '..'), { recursive: true, force: true }));
    execFileSync('git', ['clone', '-q', '--no-local', w.repo, clone]);
    execFileSync('git', ['-C', clone, 'fetch', '-q', 'origin', 'side']);
    const r = pushable({ ...w, repo: clone }, { commit: w.s2, upstream: w.c.a2 });
    assert.deepEqual([r.json.ok, r.json.uncovered.map((u) => u.commit)], [false, [w.s2, w.s1]]);
});

test('T113 (c): merging the approved worktree branch afterwards leaves the merge uncovered, the approved commits covered', needsSqlite, async (t) => {
    const w = await worktreeWorld(t);
    w.git('checkout', '-q', '-b', 'target', w.c.a2);
    w.git('commit', '-q', '--allow-empty', '-m', 'subject of t1');
    const t1 = w.git('rev-parse', 'HEAD');
    w.git('merge', '-q', '--no-edit', 'side');
    const merge = w.git('rev-parse', 'HEAD');
    const r = pushable(w, { commit: merge, upstream: w.c.a2 });
    assert.equal(r.json.ok, false);
    assert.deepEqual(new Set(r.json.uncovered.map((u) => u.commit)), new Set([merge, t1]));
    assert.equal(r.json.covered, 2, 's1 and s2');
});

test('T113: a worktree removed and pruned no longer counts: its path is not one of the repository\'s worktrees', needsSqlite, async (t) => {
    const w = await worktreeWorld(t);
    w.git('worktree', 'remove', '--force', w.wt);
    const r = pushable(w, { commit: w.s2, upstream: w.c.a2 });
    assert.deepEqual([r.json.ok, r.json.uncovered.length], [false, 2]);
});

test('T120 (R39 L2): from the main folder, a clone made where a worktree was removed but not pruned is not that worktree', needsSqlite, async (t) => {
    const w = await worktreeWorld(t);
    rmSync(w.wt, { recursive: true, force: true });
    assert.match(w.git('worktree', 'list', '--porcelain'), new RegExp(`worktree ${w.wt}\n`), 'git still lists the removed worktree');
    execFileSync('git', ['clone', '-q', '--no-local', w.repo, w.wt]);
    execFileSync('git', ['-C', w.wt, 'fetch', '-q', 'origin', 'side']);
    const fromMain = pushable(w, { commit: w.s2, upstream: w.c.a2 });
    assert.deepEqual([fromMain.json.ok, fromMain.json.uncovered.length], [false, 2], 'the worktree is gone: its approvals no longer count');
});

test('what cannot be judged is an error, never ok: an unknown commit, no range, a team without a board', needsSqlite, async (t) => {
    const w = await world(t);
    assert.deepEqual([pushable(w, { commit: 'f'.repeat(40), upstream: w.c.base }).json.code], ['invalid']);
    assert.deepEqual([pushable(w, { commit: w.c.a2 }).json.code], ['invalid']);
    assert.deepEqual([pushable(w, { commit: w.c.a2, upstream: w.c.base, baseline: 'nope' }).json.code], ['invalid']);
    const r = pushable(w, { team_name: 'nobody', commit: w.c.a2, upstream: w.c.base });
    assert.deepEqual([r.code, r.json.ok, r.json.code], [1, false, 'not-found']);
});
