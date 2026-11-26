/**
 * The SQLite adapter (T63b): the store contract, plus what only a file shared by
 * processes has — concurrent writers, the PRAGMA order, migration, a schema newer than the code, the
 * ExperimentalWarning and a Node without node:sqlite. Every database lives in a temporary folder. On a Node
 * without node:sqlite (before 22.13 / 23.4) every test that needs it is skipped, not failed.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'child_process';
import { mkdtempSync, rmSync, statSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { runStoreContract } from './store-contract.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';
import { MIGRATIONS } from '../../src/board/store/sqlite/schema.js';
import { SCHEMA_VERSION } from '../../src/board/core/contract.js';

const sqlite = await import('node:sqlite').catch(() => null);
const needsSqlite = sqlite ? {} : { skip: `node:sqlite needs Node >= 22.13 (this is ${process.version})` };
const DatabaseSync = sqlite?.Database ?? sqlite?.DatabaseSync;

const ADAPTER = fileURLToPath(new URL('../../src/board/store/sqlite/index.js', import.meta.url));
const AT = '2026-11-11T08:00:00.000Z';

function tempFile(t) {
    const dir = mkdtempSync(join(tmpdir(), 'mt-board-'));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    return join(dir, 'board.db');
}

runStoreContract('sqlite', (t) => createSqliteStore(tempFile(t)), {
    skip: needsSqlite.skip,
    makeNewerStore(t) {
        const file = tempFile(t);
        const raw = new DatabaseSync(file);
        raw.exec(`PRAGMA user_version = ${SCHEMA_VERSION + 1}`);
        raw.close();
        return createSqliteStore(file);
    },
});

/** Runs `body` (an async function's text, with `store` open on `file`) in a new node process; resolves its stdout and stderr. */
function child(file, body, options = '{}') {
    const script = `
        const { createSqliteStore } = await import(${JSON.stringify(ADAPTER)});
        const store = createSqliteStore(${JSON.stringify(file)}, ${options});
        try { await store.open(); ${body} } finally { await store.close(); }
    `;
    return new Promise((resolve, reject) => {
        const p = spawn(process.execPath, ['--input-type=module', '-e', script], { stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '', err = '';
        p.stdout.on('data', (d) => { out += d; });
        p.stderr.on('data', (d) => { err += d; });
        p.on('error', reject);
        p.on('close', (code) => resolve({ code, out: out.trim(), err }));
    });
}

test('[sqlite] of 8 processes updating one row at one version, exactly one wins', needsSqlite, async (t) => {
    const file = tempFile(t);
    const store = createSqliteStore(file);
    await store.open();
    await store.apply({ creates: [{ kind: 'task', row: { id: 'T1', title: 't', state: 'new', priority: 1, created_at: AT, created_by: 'pm' } }] });
    await store.close();
    const runs = await Promise.all(Array.from({ length: 8 }, (_, i) => child(file, `
        try {
            await store.apply({
                updates: [{ kind: 'task', key: 'T1', expect_version: 1, patch: { assignee: 'w${i}' } }],
                log: [{ at: '${AT}', actor: 'w${i}', action: 'assign', kind: 'task', ref: 'T1' }],
            });
            console.log('won');
        } catch (err) { console.log(err.code); }
    `)));
    assert.deepEqual(runs.map((r) => r.out).sort(), ['conflict', 'conflict', 'conflict', 'conflict', 'conflict', 'conflict', 'conflict', 'won'],
        runs.map((r) => r.err).join(''));
    await store.open();
    t.after(() => store.close());
    const row = await store.get('task', 'T1');
    assert.equal(row.version, 2);
    assert.equal((await store.logSince(0, 100)).length, 1, 'only the winner logged');
});

test('[sqlite] 8 processes opening a new file at once all migrate it and write', needsSqlite, async (t) => {
    const file = tempFile(t);
    const runs = await Promise.all(Array.from({ length: 8 }, (_, i) => child(file, `
        await store.apply({ creates: [{ kind: 'note', row: { body: 'n${i}', created_at: '${AT}', created_by: 'w' } }] });
        console.log('ok');
    `)));
    assert.deepEqual(runs.map((r) => r.out), Array(8).fill('ok'), runs.map((r) => r.err).join(''));
    const store = createSqliteStore(file);
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.list('note', {})).length, 8);
});

/**
 * T227: switching a new file to WAL rewrites its header from inside a read, and SQLite gets BUSY at once for that
 * upgrade, busy_timeout or not. Here the 8 processes load node:sqlite, then wait for one instant and open together.
 */
test('[sqlite] T227: 8 processes switching a new file to WAL at the same instant all open it and write', needsSqlite, async (t) => {
    const file = tempFile(t);
    const at = Date.now() + 2000;
    const load = `{ load: async () => { const m = await import('node:sqlite'); while (Date.now() < ${at}); return m; } }`;
    const runs = await Promise.all(Array.from({ length: 8 }, (_, i) => child(file, `
        await store.apply({ creates: [{ kind: 'note', row: { body: 'n${i}', created_at: '${AT}', created_by: 'w' } }] });
        console.log('ok');
    `, load)));
    assert.deepEqual(runs.map((r) => r.out), Array(8).fill('ok'), runs.map((r) => r.err).join(''));
});

test('[sqlite] busy_timeout is set before journal_mode, and every transaction begins IMMEDIATE, so a first open waits instead of failing', needsSqlite, async (t) => {
    const trace = [];
    const store = createSqliteStore(tempFile(t), { trace: (sql) => trace.push(sql) });
    await store.open();
    t.after(() => store.close());
    const pragmas = trace.filter((s) => /^PRAGMA/i.test(s));
    assert.match(pragmas[0], /^PRAGMA busy_timeout\s*=\s*5000$/i);
    assert.match(pragmas[1], /^PRAGMA journal_mode\s*=\s*WAL$/i);
    await store.apply({ creates: [{ kind: 'note', row: { body: 'b', created_at: AT, created_by: 'w' } }] });
    const begins = trace.filter((s) => /^BEGIN/i.test(s));
    assert.equal(begins.length, 2, 'the migration and the apply');
    for (const b of begins) assert.equal(b, 'BEGIN IMMEDIATE');
    await store.close();
    trace.length = 0;
    await store.open();
    assert.deepEqual(trace.filter((s) => /^BEGIN/i.test(s)), [], 'a file at the current schema opens without a transaction');
});

test('[sqlite] while another connection holds the write lock, opening a current file and reading do not wait', needsSqlite, async (t) => {
    const file = tempFile(t);
    const store = createSqliteStore(file);
    await store.open();
    await store.apply({ creates: [{ kind: 'task', row: { id: 'T1', title: 't', state: 'new', priority: 1, created_at: AT, created_by: 'pm' } }] });
    await store.close();
    const writer = new DatabaseSync(file);
    writer.exec('PRAGMA busy_timeout = 0; BEGIN IMMEDIATE');
    t.after(() => { writer.exec('ROLLBACK'); writer.close(); });
    const t0 = Date.now();
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.get('task', 'T1')).title, 't');
    assert.equal((await store.list('task', {})).length, 1);
    assert.ok(Date.now() - t0 < 1000, `took ${Date.now() - t0}ms: open or a read waited on the write lock`);
});

test('[sqlite] the file is WAL, private to the user, and keeps rows across opens at one schema version', needsSqlite, async (t) => {
    const file = tempFile(t);
    const store = createSqliteStore(file);
    await store.open();
    await store.apply({ creates: [{ kind: 'announcement', row: { body: 'hello', created_at: AT, created_by: 'pm' } }] });
    await store.close();
    await store.open();
    t.after(() => store.close());
    assert.deepEqual((await store.list('announcement', {})).map((a) => a.body), ['hello']);
    assert.equal((await store.describe()).schema_version, SCHEMA_VERSION);
    assert.equal((await store.describe()).location, file);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    const raw = new DatabaseSync(file);
    t.after(() => raw.close());
    assert.equal(raw.prepare('PRAGMA journal_mode').get().journal_mode, 'wal');
    assert.equal(raw.prepare('PRAGMA user_version').get().user_version, SCHEMA_VERSION);
});

test('[sqlite] a version 2 file migrates to 3: its landings stay, and the review report path may be left out', needsSqlite, async (t) => {
    const file = tempFile(t);
    const raw = new DatabaseSync(file);
    for (const m of MIGRATIONS.filter((x) => x.to <= 2)) raw.exec(m.sql);
    raw.exec('PRAGMA user_version = 2');
    raw.prepare(`INSERT INTO landings VALUES ('T1#1','T1','/r','${'a'.repeat(40)}','${'b'.repeat(40)}','[]','c','r','["f"]','[]','/p','/q',NULL,NULL,'${AT}','core',NULL,NULL,1,'[]')`).run();
    const id = raw.prepare(`SELECT "value" FROM meta`).get().value;
    raw.close();
    const store = createSqliteStore(file);
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.get('landing', 'T1#1')).review_report_path, '/q');
    assert.equal((await store.describe()).board_id, id, 'the board id stays');
    await store.apply({ creates: [{ kind: 'landing', row: { id: 'T1#2', task_id: 'T1', repo: '/r', commit: 'c'.repeat(40), base_commit: 'b'.repeat(40), commits: [], check_cmd: 'c', check_result: 'r', focus: ['f'], closes: [], report_path: '/p', created_at: AT, created_by: 'core' } }] });
    assert.equal((await store.get('landing', 'T1#2')).review_report_path, null);
    assert.deepEqual((await store.list('landing', { task_id: 'T1' })).map((l) => l.id), ['T1#1', 'T1#2']);
    await store.close();
    const check = new DatabaseSync(file);
    const indexes = check.prepare(`SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'landings' AND name NOT LIKE 'sqlite_%'`).all().map((r) => r.name);
    check.close();
    assert.deepEqual(indexes, ['landings_task'], 'the rebuilt table keeps its index');
    await store.open();
});

test('[sqlite] a version 3 file migrates: its tasks, verdicts and findings stay, and a task can keep a waiting question', needsSqlite, async (t) => {
    const file = tempFile(t);
    const raw = new DatabaseSync(file);
    for (const m of MIGRATIONS.filter((x) => x.to <= 3)) raw.exec(m.sql);
    raw.exec('PRAGMA user_version = 3');
    raw.prepare(`INSERT INTO tasks VALUES ('T1',NULL,'t','/t','review','core','rv',100,NULL,'없음',NULL,'${AT}','pm',NULL,NULL,3)`).run();
    raw.prepare(`INSERT INTO verdicts VALUES ('R1','T1#1','changes','${'a'.repeat(40)}','/r','c','r',NULL,'${AT}','rv')`).run();
    raw.prepare(`INSERT INTO findings VALUES ('R1 M1','R1','T1','must','s','r','open',NULL,'${AT}','rv',NULL,NULL,1)`).run();
    const id = raw.prepare(`SELECT "value" FROM meta`).get().value;
    raw.close();
    const store = createSqliteStore(file);
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.describe()).schema_version, SCHEMA_VERSION);
    assert.equal((await store.describe()).board_id, id);
    const task = await store.get('task', 'T1');
    assert.deepEqual([task.state, task.constraints, task.version, task.waiting], ['review', '없음', 3, null]);
    assert.equal((await store.get('verdict', 'R1')).verdict, 'changes');
    assert.equal((await store.get('finding', 'R1 M1')).state, 'open');
    const waiting = {
        question: 'q', context: 'c', options: [{ label: 'A', detail: '', pros: ['p'], cons: ['c'] }, { label: 'B', detail: 'd', pros: ['p'], cons: ['c'] }],
        recommendation: { option: null, reason: 'r' }, impact: 'i', refs: [], asked_by: 'pm', asked_at: AT, resume_state: 'review',
    };
    await store.apply({ updates: [{ kind: 'task', key: 'T1', expect_version: 3, patch: { state: 'waiting', waiting } }] });
    assert.deepEqual((await store.get('task', 'T1')).waiting, waiting);
});

test('[sqlite] a version 4 file migrates to 5: its rows stay, and it keeps decisions (T146)', needsSqlite, async (t) => {
    const file = tempFile(t);
    const raw = new DatabaseSync(file);
    for (const m of MIGRATIONS.filter((x) => x.to <= 4)) raw.exec(m.sql);
    raw.exec('PRAGMA user_version = 4');
    raw.prepare(`INSERT INTO tasks VALUES ('T1',NULL,'t','/t','doing','core','rv',100,NULL,'없음',NULL,'${AT}','pm',NULL,NULL,2,NULL)`).run();
    raw.prepare(`INSERT INTO log ("at","actor","action","kind","ref","state_from","state_to","detail") VALUES ('${AT}','pm','wait','task','T1','doing','waiting','{"question":"q"}')`).run();
    raw.close();
    const store = createSqliteStore(file);
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.describe()).schema_version, SCHEMA_VERSION);
    assert.deepEqual([(await store.get('task', 'T1')).state, (await store.logSince(0, 10)).length], ['doing', 1]);
    const row = { id: 'D1', tasks: ['T1'], brief: { question: 'q' }, state: 'open', answer: null, created_at: AT, created_by: 'core' };
    await store.apply({ creates: [{ kind: 'decision', row }] });
    assert.deepEqual((await store.list('decision', { state: 'open' })).map((d) => [d.id, d.tasks, d.version]), [['D1', ['T1'], 1]]);
});

test('[sqlite] a version 1 file migrates: its rows stay, it gains a board id kept across opens, and landings a left_out list', needsSqlite, async (t) => {
    const file = tempFile(t);
    const raw = new DatabaseSync(file);
    raw.exec(MIGRATIONS.find((m) => m.to === 1).sql);
    raw.exec('PRAGMA user_version = 1');
    raw.prepare(`INSERT INTO landings VALUES ('T1#1','T1','/r','${'a'.repeat(40)}','${'b'.repeat(40)}','[]','c','r','["f"]','[]','/p','/q',NULL,NULL,'${AT}','core',NULL,NULL,1)`).run();
    raw.close();
    const store = createSqliteStore(file);
    await store.open();
    const id = (await store.describe()).board_id;
    assert.match(id, /^[0-9a-f]{32}$/);
    assert.deepEqual((await store.get('landing', 'T1#1')).left_out, null, 'an old row has no left_out');
    await store.close();
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.describe()).board_id, id);
    assert.equal((await store.describe()).schema_version, SCHEMA_VERSION);
});

test('[sqlite] R21 L1: a switch to WAL that answers another mode fails the open, naming the mode', needsSqlite, async (t) => {
    class StaysDelete extends DatabaseSync {
        prepare(sql) {
            if (/^PRAGMA journal_mode\s*=\s*WAL$/i.test(sql)) return { get: () => ({ journal_mode: 'delete' }) };
            return super.prepare(sql);
        }
    }
    const store = createSqliteStore(tempFile(t), { load: async () => ({ DatabaseSync: StaysDelete }) });
    await assert.rejects(store.open(), (err) => {
        assert.equal(err.code, 'store');
        assert.match(err.message, /journal_mode delete/);
        return true;
    });
});

test('[sqlite] a Node without node:sqlite makes the board unavailable, naming the Node it needs', async (t) => {
    const missing = Object.assign(new Error("No such built-in module: node:sqlite"), { code: 'ERR_UNKNOWN_BUILTIN_MODULE' });
    const store = createSqliteStore(tempFile(t), { load: async () => { throw missing; } });
    await assert.rejects(store.open(), (err) => {
        assert.equal(err.code, 'board-unavailable');
        assert.match(err.message, /Node >= 22\.13/);
        assert.match(err.message, new RegExp(process.version.replaceAll('.', '\\.')));
        return true;
    });
});

test("[sqlite] a warning other than SQLite's, raised while node:sqlite loads, still prints", needsSqlite, async (t) => {
    const run = await child(tempFile(t), `console.log('ok');`, `{ load: async () => {
        process.emitWarning('raised while loading', 'ExperimentalWarning');
        process.emitWarning('SQLite look-alike', 'ExperimentalWarning');
        return import('node:sqlite');
    } }`);
    assert.equal(run.out, 'ok', run.err);
    assert.match(run.err, /raised while loading/);
    assert.doesNotMatch(run.err, /SQLite/);
});

test("[sqlite] opening prints no SQLite ExperimentalWarning, and other warnings still print", needsSqlite, async (t) => {
    const run = await child(tempFile(t), `
        process.emitWarning('a later warning', 'ExperimentalWarning');
        await new Promise((r) => setImmediate(r));
        console.log('ok');
    `);
    assert.equal(run.out, 'ok', run.err);
    assert.doesNotMatch(run.err, /SQLite/);
    assert.match(run.err, /a later warning/);
});

test('[sqlite] a version 5 file migrates to 6: its tasks stay, none a document task, and a task can be one (T158)', needsSqlite, async (t) => {
    const file = tempFile(t);
    const raw = new DatabaseSync(file);
    for (const m of MIGRATIONS.filter((x) => x.to <= 5)) raw.exec(m.sql);
    raw.exec('PRAGMA user_version = 5');
    raw.prepare(`INSERT INTO tasks VALUES ('T1',NULL,'t','/t','doing','core','rv',100,NULL,'없음',NULL,'${AT}','pm',NULL,NULL,2,NULL)`).run();
    raw.close();
    const store = createSqliteStore(file);
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.describe()).schema_version, SCHEMA_VERSION);
    const task = await store.get('task', 'T1');
    assert.deepEqual([task.state, task.deliverable, task.version], ['doing', null, 2]);
    await store.apply({ updates: [{ kind: 'task', key: 'T1', expect_version: 2, patch: { deliverable: 'document' } }] });
    assert.equal((await store.get('task', 'T1')).deliverable, 'document');
});

test('[sqlite] a version 6 file migrates to 7: its landings and verdicts stay, with no structured check, and take one (T53)', needsSqlite, async (t) => {
    const file = tempFile(t);
    const raw = new DatabaseSync(file);
    for (const m of MIGRATIONS.filter((x) => x.to <= 6)) raw.exec(m.sql);
    raw.exec('PRAGMA user_version = 6');
    const C = 'a'.repeat(40);
    raw.prepare(`INSERT INTO landings VALUES ('T1#1','T1','/repo','${C}','${C}','["${C}"]','npm test','10/10','["one"]','[]','/r.md',NULL,NULL,NULL,'${AT}','core',NULL,NULL,1,'[]')`).run();
    raw.prepare(`INSERT INTO verdicts VALUES ('R1','T1#1','approve','${C}','/R.md','npm test','10/10',NULL,'${AT}','rv')`).run();
    raw.close();
    const store = createSqliteStore(file);
    await store.open();
    t.after(() => store.close());
    assert.equal((await store.describe()).schema_version, 7);
    const landing = await store.get('landing', 'T1#1');
    assert.deepEqual([landing.check_result, landing.check_detail, landing.unverified, landing.version], ['10/10', null, null, 1]);
    assert.deepEqual([(await store.get('verdict', 'R1')).rerun_result, (await store.get('verdict', 'R1')).rerun_detail], ['10/10', null]);
    const detail = { counts: { pass: 9, fail: 1, skip: 0 }, failures: ['a: b'], excused: [] };
    await store.apply({ updates: [{ kind: 'landing', key: 'T1#1', expect_version: 1, patch: { check_detail: detail, unverified: ['x'] } }] });
    const after = await store.get('landing', 'T1#1');
    assert.deepEqual([after.check_detail, after.unverified], [detail, ['x']]);
});
