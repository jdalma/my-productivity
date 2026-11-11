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

test('what cannot be judged is an error, never ok: an unknown commit, no range, a team without a board', needsSqlite, async (t) => {
    const w = await world(t);
    assert.deepEqual([pushable(w, { commit: 'f'.repeat(40), upstream: w.c.base }).json.code], ['invalid']);
    assert.deepEqual([pushable(w, { commit: w.c.a2 }).json.code], ['invalid']);
    assert.deepEqual([pushable(w, { commit: w.c.a2, upstream: w.c.base, baseline: 'nope' }).json.code], ['invalid']);
    const r = pushable(w, { team_name: 'nobody', commit: w.c.a2, upstream: w.c.base });
    assert.deepEqual([r.code, r.json.ok, r.json.code], [1, false, 'not-found']);
});
