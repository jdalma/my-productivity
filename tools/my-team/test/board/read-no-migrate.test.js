/**
 * Reading a board never changes its file (T159): a read command on a board.db of an older schema reads it as the
 * migration would leave it, without migrating; a write command migrates and first leaves a copy beside the file.
 * Through the real CLI, on a scratch repository and a temporary state base whose manifest names that base.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { openBoard } from '../../src/board/compose.js';
import { createBoard } from '../../src/board/core/service.js';
import { SCHEMA_VERSION, StoreError } from '../../src/board/core/contract.js';
import { gitRange } from '../../src/board/git.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));
const sqlite = await import('node:sqlite').catch(() => null);
const needsSqlite = sqlite ? {} : { skip: 'node:sqlite needs Node >= 22.13' };
const DatabaseSync = sqlite?.Database ?? sqlite?.DatabaseSync;
const ROSTER = [{ name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' }, { name: 'rv', role: 'worker' }];
const OLD = SCHEMA_VERSION - 1;

function scratch(t, prefix) {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    return dir;
}

/** A team `name` under `base`; its manifest's state_root is under `base` too. */
function team(base, name) {
    const root = join(base, name);
    mkdirSync(root, { recursive: true });
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: name, state_root: root, session_name: `my-team-${name}-x:0`, board: { store: 'sqlite' },
        workers: ROSTER.map((w) => ({ name: w.name, role: w.role, agent_type: 'claude', pane_id: '%999', cwd: base })),
    }));
    return root;
}

function cli(base, command, input, worker) {
    const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base };
    for (const k of ['MY_TEAM_WORKER', 'OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
    if (worker) env.MY_TEAM_WORKER = worker;
    const r = spawnSync(process.execPath, [MY_TEAM, 'api', command, '--input', JSON.stringify(input), '--json'], { env, encoding: 'utf-8' });
    let json = null;
    try { json = JSON.parse(r.stdout); } catch { /* not JSON */ }
    return { code: r.status, json, err: r.stderr };
}

const pragma = (file, name) => { const db = new DatabaseSync(file); try { return Object.values(db.prepare(`PRAGMA ${name}`).get())[0]; } finally { db.close(); } };

/**
 * A board.db of the schema before this one at `file`, with a task approved, one in review, a finding, a note and a
 * decision: written by this code, then taken back one schema as its last migration is undone.
 */
async function oldBoard(file, repo, commits) {
    const store = createSqliteStore(file);
    await store.open();
    let tick = 0;
    const now = () => new Date(Date.UTC(2026, 10, 11, 0, 0, tick++)).toISOString();
    const as = (actor) => createBoard({ store, roster: () => ROSTER, actor, now, git: gitRange });
    const landing = (id, commit) => ({ id, repo, commit, check: { cmd: 'npm test', result: 'ok' }, focus: ['f'], closes: [], report: '/r.md', review_report: '/R.md' });
    const verdict = (l, commit, v, findings = []) => ({ landing: l, verdict: v, verified_commit: commit, rerun: { cmd: 'npm test', result: 'ok' }, findings });
    await as('pm').add({ id: 'T1', title: 'one', assignee: 'core', reviewer: 'rv', ticket: '/t.md', constraints: 'c', base: commits.base });
    await as('core').take({ id: 'T1' });
    await as('core').land(landing('T1', commits.a));
    await as('rv').verdict(verdict('T1#1', commits.a, 'approve', [{ code: 'L1', severity: 'low', summary: 's', repro: 'r' }]));
    await as('pm').add({ id: 'T2', title: 'two', assignee: 'core', reviewer: 'rv', ticket: '/t.md', constraints: 'c', base: commits.a });
    await as('core').take({ id: 'T2' });
    await as('core').progress({ id: 'T2', item: 1, note: 'half', done: false });
    await as('core').land(landing('T2', commits.b));
    await as('core').note({ id: 'T2', body: 'why', to: ['pm'] });
    await as('pm').announce({ body: 'hello' });
    await as('core').ask({
        question: 'A or B?', context: 'c', impact: 'i', recommendation: { option: 'A', reason: 'r' }, tasks: ['T2'],
        options: [{ label: 'A', pros: ['p'], cons: ['c'] }, { label: 'B', pros: ['p'], cons: ['c'] }],
    });
    await store.close();
    const raw = new DatabaseSync(file);
    raw.exec('PRAGMA journal_mode = DELETE');   // one file, so its bytes are the whole board
    raw.exec(`ALTER TABLE tasks DROP COLUMN "deliverable"; PRAGMA user_version = ${OLD}`);
    raw.close();
}

async function world(t) {
    const repo = scratch(t, 'mt-nomig-repo-');
    const git = (...args) => execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { encoding: 'utf-8' }).trim();
    git('init', '-q', '-b', 'main');
    const commit = (name) => { writeFileSync(join(repo, name), name); git('add', name); git('commit', '-q', '-m', name); return git('rev-parse', 'HEAD'); };
    const commits = { base: commit('base'), a: commit('a'), b: commit('b') };
    const base = scratch(t, 'mt-nomig-state-');
    const root = team(base, 'old');
    await oldBoard(join(root, 'board.db'), repo, commits);
    return { repo, commits, base, root, file: join(root, 'board.db') };
}

/** The four read commands on team `name`: [command, input, worker]. */
const reads = (name, w) => [
    ['board-status', { team_name: name }],
    ['board-status', { team_name: name, task: 'T2' }],
    ['board-inbox', { team_name: name }, `${name}/core`],
    ['board-review-queue', { team_name: name }, `${name}/rv`],
    ['board-pushable', { team_name: name, repo: w.repo, commit: w.commits.b, upstream: w.commits.base }],
];

test(`the read commands leave a schema ${OLD} board.db as it is, and read what a migrated one says`, needsSqlite, async (t) => {
    const w = await world(t);
    // the same board, migrated, as another team beside it
    const migratedRoot = team(w.base, 'new');
    copyFileSync(w.file, join(migratedRoot, 'board.db'));
    const store = createSqliteStore(join(migratedRoot, 'board.db'));
    await store.open();
    await store.close();
    assert.equal(pragma(join(migratedRoot, 'board.db'), 'user_version'), SCHEMA_VERSION);

    const before = readFileSync(w.file);
    const tables = () => { const db = new DatabaseSync(w.file); try { return db.prepare('SELECT name, sql FROM sqlite_master ORDER BY name').all(); } finally { db.close(); } };
    const defined = tables();
    const same = (json) => JSON.parse(JSON.stringify(json).replaceAll(migratedRoot, w.root).replaceAll('"new"', '"old"'));
    for (const [i, [command, input, worker]] of reads('old', w).entries()) {
        const old = cli(w.base, command, input, worker);
        assert.equal(old.code, 0, `${command}: ${old.err}`);
        const [, newInput, newWorker] = reads('new', w)[i];
        const migrated = cli(w.base, command, newInput, newWorker);
        assert.equal(migrated.code, 0, `${command} (migrated): ${migrated.err}`);
        assert.deepEqual(old.json, same(migrated.json), `${command} ${JSON.stringify(input)} reads the same`);
        assert.ok(readFileSync(w.file).equals(before), `${command} left the file's bytes`);
    }
    assert.equal(pragma(w.file, 'user_version'), OLD);
    assert.deepEqual(tables(), defined);
    assert.deepEqual(readdirSync(w.root).filter((f) => f.endsWith('.bak')), [], 'a read leaves no copy either');

    const status = cli(w.base, 'board-status', { team_name: 'old' }).json;
    assert.deepEqual(status.tasks.map((x) => [x.id, x.state, x.deliverable]), [['T1', 'done', null], ['T2', 'review', null]]);
    assert.deepEqual([status.open_findings.length, status.decisions.length, status.announcements.length], [1, 1, 1]);
    const pushable = cli(w.base, 'board-pushable', reads('old', w)[4][1]).json;
    assert.deepEqual([pushable.covered, pushable.uncovered.map((c) => c.commit)], [1, [w.commits.b]]);
});

test('a read of a team that has no board.db yet reads an empty board and makes no file', needsSqlite, (t) => {
    const base = scratch(t, 'mt-nomig-state-');
    const root = team(base, 'fresh');
    const status = cli(base, 'board-status', { team_name: 'fresh' });
    assert.equal(status.code, 0, status.err);
    assert.deepEqual([status.json.tasks, status.json.store.schema_version], [[], SCHEMA_VERSION]);
    assert.equal(cli(base, 'board-inbox', { team_name: 'fresh' }, 'fresh/core').code, 0);
    assert.deepEqual(readdirSync(root), ['manifest.json']);
});

test(`a write command migrates a schema ${OLD} board.db and first leaves board.db.v${OLD}.bak, once`, needsSqlite, async (t) => {
    const w = await world(t);
    const bak = `${w.file}.v${OLD}.bak`;
    const before = cli(w.base, 'board-status', { team_name: 'old' }).json;
    const note = cli(w.base, 'board-note', { team_name: 'old', body: 'first write' }, 'old/pm');
    assert.equal(note.code, 0, note.err);
    assert.equal(pragma(w.file, 'user_version'), SCHEMA_VERSION);
    assert.equal(pragma(bak, 'user_version'), OLD, 'the copy is the board as it was');
    const db = new DatabaseSync(bak);
    assert.deepEqual(db.prepare('SELECT id, state FROM tasks ORDER BY id').all().map((r) => [r.id, r.state]), [['T1', 'done'], ['T2', 'review']]);
    assert.equal(db.prepare('SELECT count(*) AS n FROM notes').get().n, 1, 'without the write that migrated');
    db.close();
    assert.deepEqual(readdirSync(w.root).filter((f) => f.includes('.tmp')), []);
    const after = cli(w.base, 'board-status', { team_name: 'old' }).json;
    assert.deepEqual(after.tasks, before.tasks, 'what the read said before the migration, the board says after it');

    // a copy that is there is kept: a later migration from the same schema does not write over it
    const kept = readFileSync(bak);
    const raw = new DatabaseSync(w.file);
    raw.exec(`ALTER TABLE tasks DROP COLUMN "deliverable"; PRAGMA user_version = ${OLD}`);
    raw.close();
    assert.equal(cli(w.base, 'board-note', { team_name: 'old', body: 'second' }, 'old/pm').code, 0);
    assert.equal(pragma(w.file, 'user_version'), SCHEMA_VERSION);
    assert.ok(readFileSync(bak).equals(kept));
});

test('a board a newer my-team wrote: the error says what to do, for a read and for a write', needsSqlite, async (t) => {
    const w = await world(t);
    const raw = new DatabaseSync(w.file);
    raw.exec(`PRAGMA user_version = ${SCHEMA_VERSION + 1}`);
    raw.close();
    for (const [command, input, worker] of [['board-status', { team_name: 'old' }], ['board-note', { team_name: 'old', body: 'x' }, 'old/pm']]) {
        const r = cli(w.base, command, input, worker);
        assert.deepEqual([r.code, r.json.code], [1, 'schema-too-new'], command);
        assert.match(r.json.message, /install a newer my-team/);
        assert.match(r.json.message, new RegExp(`board\\.db\\.v<n>\\.bak`));
    }
    assert.equal(pragma(w.file, 'user_version'), SCHEMA_VERSION + 1);
});

test('a store opened for reading refuses a write', needsSqlite, async (t) => {
    const dir = scratch(t, 'mt-nomig-store-');
    for (const name of ['current.db', 'missing.db']) {
        const file = join(dir, name);
        if (name === 'current.db') { const s = createSqliteStore(file); await s.open(); await s.close(); }
        const store = createSqliteStore(file);
        await store.open({ readonly: true });
        await assert.rejects(store.apply({ log: [{ at: 'x', actor: 'pm', action: 'note', kind: 'note', ref: '-' }] }), (err) => err instanceof StoreError && /opened for reading/.test(err.message));
        assert.equal((await store.describe()).schema_version, SCHEMA_VERSION);
        await store.close();
    }
    assert.equal(existsSync(join(dir, 'missing.db')), false);
});

test(`a schema ${OLD} board.db in WAL mode, with a writer's connection open, is read and stays at its schema`, needsSqlite, async (t) => {
    const w = await world(t);
    const writer = new DatabaseSync(w.file);
    t.after(() => { try { writer.close(); } catch { /* closed */ } });
    writer.exec('PRAGMA journal_mode = WAL');
    writer.exec(`UPDATE tasks SET "title" = 'renamed in the WAL' WHERE "id" = 'T2'`);
    const status = cli(w.base, 'board-status', { team_name: 'old' });
    assert.equal(status.code, 0, status.err);
    assert.equal(status.json.tasks.find((x) => x.id === 'T2').title, 'renamed in the WAL', 'what is in the WAL is read too');
    assert.equal(writer.prepare('PRAGMA user_version').get().user_version, OLD);
    assert.equal(writer.prepare(`SELECT count(*) AS n FROM pragma_table_info('tasks') WHERE name = 'deliverable'`).get().n, 0);
    writer.exec(`UPDATE tasks SET "title" = 'two' WHERE "id" = 'T2'`);   // and the writer is not locked out
});

test(`a write on a running team's schema ${OLD} board.db is refused, and migrates once the team is down (T50)`, needsSqlite, async (t) => {
    const w = await world(t);
    const saved = process.env.MY_TEAM_STATE_ROOT_BASE;
    process.env.MY_TEAM_STATE_ROOT_BASE = w.base;
    t.after(() => { if (saved === undefined) delete process.env.MY_TEAM_STATE_ROOT_BASE; else process.env.MY_TEAM_STATE_ROOT_BASE = saved; });
    const running = async () => [{ session: 'my-team-old-x', worker: 'core', paneId: '%999' }];
    const before = readFileSync(w.file);

    await assert.rejects(openBoard('old', { write: true, panes: running }), (err) => {
        assert.equal(err.code, 'migration-refused');
        assert.match(err.message, new RegExp(`schema ${OLD}, older than this my-team's ${SCHEMA_VERSION}`));
        assert.match(err.message, /MY_TEAM_STATE_ROOT_BASE/);
        assert.match(err.message, /state_root/);
        assert.match(err.message, /session_name/);
        return true;
    });
    assert.ok(readFileSync(w.file).equals(before), 'the file is left as it was');
    assert.deepEqual(readdirSync(w.root).filter((f) => f.endsWith('.bak')), [], 'and no copy is made');

    const read = await openBoard('old', { panes: running });   // a read migrates nothing, so it is not refused
    await read.close();

    const down = await openBoard('old', { write: true, panes: async () => [] });
    await down.close();
    assert.equal(pragma(w.file, 'user_version'), SCHEMA_VERSION);

    const current = await openBoard('old', { write: true, panes: running });   // at SCHEMA_VERSION a running team writes as before
    await current.close();
});
