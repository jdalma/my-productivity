/**
 * The SQLite adapter (T63b, rfc/board-design.md §5): the store contract, plus what only a file shared by
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
