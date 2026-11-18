/**
 * The board store on SQLite (T63b), through node:sqlite: no dependency to install,
 * one file per team (<state_root>/board.db). Each my-team call opens, does its work and closes.
 *
 * - busy_timeout is set before journal_mode: switching a new file to WAL takes a lock, and without the
 *   timeout a process that meets it fails at once instead of waiting (reports/T63-pragma-order).
 * - Every transaction is BEGIN IMMEDIATE. The migration reads user_version and then writes; two processes
 *   holding a read lock that both ask to write make SQLite fail one at once, without waiting. apply()
 *   matches an update's expected version in its WHERE clause.
 * - open() takes no lock on a file already at SCHEMA_VERSION: it reads user_version first and opens the
 *   migration transaction only when the file is behind, so reads never wait on a writer (WAL).
 * - The file is created 0600 before SQLite opens it; -wal and -shm take the same mode.
 * - open({ readonly: true }) never changes the file (T159): a read of a board must not move it to a schema the
 *   my-team installed for everyone else refuses. A file behind SCHEMA_VERSION is copied into memory and migrated
 *   there; a file that is not there yet reads as an empty board and is not made. apply() is refused.
 * - A migration of a file that holds a board first leaves a copy beside it, <file>.v<n>.bak (n its schema before);
 *   a copy already there is kept.
 * - node:sqlite needs Node 22.13 / 23.4; on an older Node, open() throws Unavailable and only the board stops.
 */

import { chmodSync, closeSync, existsSync, linkSync, openSync, rmSync } from 'node:fs';

import {
    KINDS, LOG_FIELDS, SCHEMA_VERSION, Busy, Conflict, SchemaTooNew, StoreError, Unavailable,
    checkChanges, checkKey, checkQuery, fullLog, fullRow,
} from '../../core/contract.js';
import { MIGRATIONS, TABLES } from './schema.js';

const BUSY_MS = 5000;
const q = (name) => `"${name}"`;
const quoted = (text) => `'${text.replaceAll("'", "''")}'`;
/** The copy a migration leaves of a board at schema `version` (T159). */
export const backupOf = (file, version) => `${file}.v${version}.bak`;

const loadSqlite = () => import('node:sqlite');

/**
 * Runs load() with SQLite's ExperimentalWarning (printed once per process) dropped; other warnings pass.
 * Known limit: code that replaces process.emitWarning while load() runs is undone when it ends.
 */
async function quietly(load) {
    const emit = process.emitWarning;
    process.emitWarning = function (warning, ...rest) {
        const type = typeof rest[0] === 'string' ? rest[0] : rest[0]?.type;
        if (type === 'ExperimentalWarning' && /SQLite/.test(String(warning))) return;
        return emit.call(this, warning, ...rest);
    };
    try {
        return await load();
    } finally {
        process.emitWarning = emit;
    }
}

function encode(spec, value) {
    if (value === null || value === undefined) return null;
    return spec.type === 'list' || spec.type === 'json' ? JSON.stringify(value) : value;
}

function decode(fields, raw) {
    const row = {};
    for (const [name, spec] of Object.entries(fields)) {
        const v = raw[name];
        row[name] = v === null || v === undefined ? null : spec.type === 'list' || spec.type === 'json' ? JSON.parse(v) : v;
    }
    return row;
}

function storeError(err) {
    if (err instanceof StoreError) return err;
    const primary = typeof err?.errcode === 'number' ? err.errcode & 0xff : null;
    if (err?.errcode === 1555 || err?.errcode === 2067) return new Conflict(err.message);
    if (primary === 5 || primary === 6) return new Busy(`board store busy: ${err.message}`);
    return new StoreError(err?.message ?? String(err));
}

/**
 * options.load: how node:sqlite is loaded (tests pass a failing one). options.trace: called with each PRAGMA,
 * migration and BEGIN, so their order can be checked without a race.
 */
export function createSqliteStore(file, { load = loadSqlite, trace = () => {} } = {}) {
    let db = null;
    let readonly = false;

    const exec = (sql) => { trace(sql); db.exec(sql); };
    const inTransaction = (fn) => {
        exec('BEGIN IMMEDIATE');
        try {
            const out = fn();
            db.exec('COMMIT');
            return out;
        } catch (err) {
            try { db.exec('ROLLBACK'); } catch { /* the failed statement may have ended it */ }
            throw err;
        }
    };
    const guarded = (fn) => {
        if (!db) throw new StoreError('board store is not open');
        try { return fn(); } catch (err) { throw storeError(err); }
    };

    /** The file's schema; a newer one than this code's is refused. */
    function versionNow() {
        const version = db.prepare('PRAGMA user_version').get().user_version;
        if (version > SCHEMA_VERSION) {
            throw new SchemaTooNew(
                `${file} has board schema ${version}, newer than this my-team's ${SCHEMA_VERSION}: install a newer my-team (the one that wrote it), `
                + `or put back the copy its migration left beside the file, ${backupOf(file, '<n>')} (n: the schema before)`,
            );
        }
        return version;
    }

    /**
     * The board as it is, kept beside the file before a migration changes it (T159). VACUUM INTO reads one
     * snapshot, WAL included. A copy that turns out to be of another schema (someone migrated meanwhile, and
     * left theirs) is dropped; a link fails where a copy is, so none is written over.
     */
    function keepCopy(version) {
        const target = backupOf(file, version);
        if (existsSync(target)) return;
        const tmp = `${target}.${process.pid}.tmp`;
        try {
            rmSync(tmp, { force: true });   // VACUUM INTO refuses a file that is there
            exec(`VACUUM INTO ${quoted(tmp)}`);
            exec(`ATTACH DATABASE ${quoted(tmp)} AS bak`);
            const copied = db.prepare('PRAGMA bak.user_version').get().user_version;
            exec('DETACH DATABASE bak');
            if (copied !== version) return;
            chmodSync(tmp, 0o600);
            try { linkSync(tmp, target); } catch (err) { if (err.code !== 'EEXIST') throw err; }
        } finally {
            rmSync(tmp, { force: true });
        }
    }

    function migrate() {
        const behind = versionNow();
        if (behind === SCHEMA_VERSION) return;
        if (behind > 0) keepCopy(behind);
        inTransaction(() => {
            const version = versionNow();
            for (const m of MIGRATIONS.filter((x) => x.to > version)) {
                exec(m.sql);
                exec(`PRAGMA user_version = ${m.to}`);
            }
        });
    }

    /**
     * The board for reading only. At SCHEMA_VERSION the file itself, with writes off. Behind it, or not there,
     * a database in memory: the file's tables and rows copied in one read, then migrated there.
     */
    function openForReading(Database) {
        const there = existsSync(file);
        if (there) {
            db = new Database(file);
            exec(`PRAGMA busy_timeout = ${BUSY_MS}`);
            if (versionNow() === SCHEMA_VERSION) { exec('PRAGMA query_only = ON'); return; }
            db.close();
        }
        db = new Database(':memory:');
        if (there) {
            exec(`PRAGMA busy_timeout = ${BUSY_MS}`);
            exec(`ATTACH DATABASE ${quoted(file)} AS src`);
            // a plain BEGIN: one read snapshot of the file, and no write lock asked of it
            exec('BEGIN');
            const made = db.prepare(`SELECT "type", "name", "sql" FROM src.sqlite_master WHERE "sql" IS NOT NULL AND "name" NOT LIKE 'sqlite_%'`).all();
            for (const { sql } of made.filter((m) => m.type === 'table')) exec(sql);
            for (const { name } of made.filter((m) => m.type === 'table')) exec(`INSERT INTO main.${q(name)} SELECT * FROM src.${q(name)}`);
            for (const { sql } of made.filter((m) => m.type !== 'table')) exec(sql);
            exec(`PRAGMA main.user_version = ${db.prepare('PRAGMA src.user_version').get().user_version}`);
            exec('COMMIT');
            exec('DETACH DATABASE src');
        }
        const version = versionNow();
        for (const m of MIGRATIONS.filter((x) => x.to > version)) {
            exec(m.sql);
            exec(`PRAGMA user_version = ${m.to}`);
        }
    }

    return {
        async open({ readonly: forReading = false } = {}) {
            if (db) return;
            let mod;
            try {
                mod = await quietly(load);
            } catch (err) {
                throw new Unavailable(`board needs Node >= 22.13 (this is ${process.version}): ${err.message}`);
            }
            const Database = mod.Database ?? mod.DatabaseSync;
            try {
                readonly = forReading;
                if (readonly) { openForReading(Database); return; }
                closeSync(openSync(file, 'a', 0o600));
                db = new Database(file);
                exec(`PRAGMA busy_timeout = ${BUSY_MS}`);
                exec('PRAGMA journal_mode = WAL');
                migrate();
            } catch (err) {
                try { db?.close(); } catch { /* already closed */ }
                db = null;
                throw storeError(err);
            }
        },

        async close() {
            if (!db) return;
            db.close();
            db = null;
        },

        async describe() {
            return guarded(() => ({
                adapter: 'sqlite', schema_version: db.prepare('PRAGMA user_version').get().user_version, location: file,
                board_id: db.prepare(`SELECT "value" FROM meta WHERE "key" = 'board_id'`).get().value,
            }));
        },

        async get(kind, key) {
            const def = checkKey(kind, key);
            return guarded(() => {
                const raw = db.prepare(`SELECT * FROM ${TABLES[kind]} WHERE ${q(def.key)} = ?`).get(key);
                return raw ? fullRow(kind, { ...decode(def.fields, raw), version: raw.version }) : null;
            });
        },

        async list(kind, where = {}, order) {
            const [field, dir] = checkQuery(kind, where, order);
            const def = KINDS[kind];
            return guarded(() => {
                const terms = [], args = [];
                for (const [name, want] of Object.entries(where)) {
                    if (want === null) terms.push(`${q(name)} IS NULL`);
                    else if (Array.isArray(want)) {
                        if (!want.length) { terms.push('0'); continue; }
                        const values = want.filter((v) => v !== null);
                        const parts = values.length ? [`${q(name)} IN (${values.map(() => '?').join(', ')})`] : [];
                        if (values.length < want.length) parts.push(`${q(name)} IS NULL`);
                        terms.push(`(${parts.join(' OR ')})`);
                        args.push(...values);
                    } else {
                        terms.push(`${q(name)} = ?`);
                        args.push(want);
                    }
                }
                const sql = `SELECT * FROM ${TABLES[kind]}${terms.length ? ` WHERE ${terms.join(' AND ')}` : ''}`
                    + ` ORDER BY ${q(field)} ${dir === 'asc' ? 'ASC' : 'DESC'}, ${q(def.key)} ASC`;
                return db.prepare(sql).all(...args).map((raw) => fullRow(kind, { ...decode(def.fields, raw), version: raw.version }));
            });
        },

        async apply(changes = {}) {
            if (readonly) throw new StoreError('board store opened for reading: it takes no change');
            checkChanges(changes);
            const { creates = [], updates = [], log = [] } = changes;
            return guarded(() => inTransaction(() => {
                const seqs = {};
                for (const { kind, row } of creates) {
                    const def = KINDS[kind];
                    const names = Object.keys(row);
                    const cols = [...names, ...(def.versioned ? ['version'] : [])];
                    const values = [...names.map((n) => encode(def.fields[n], row[n])), ...(def.versioned ? [1] : [])];
                    const res = db.prepare(`INSERT INTO ${TABLES[kind]} (${cols.map(q).join(', ')}) VALUES (${cols.map(() => '?').join(', ')})`)
                        .run(...values);
                    if (def.seq) (seqs[kind] ??= []).push(Number(res.lastInsertRowid));
                }
                for (const { kind, key, expect_version, patch } of updates) {
                    const def = KINDS[kind];
                    const names = Object.keys(patch ?? {});
                    const sets = [...names.map((n) => `${q(n)} = ?`), '"version" = "version" + 1'];
                    const res = db.prepare(`UPDATE ${TABLES[kind]} SET ${sets.join(', ')} WHERE ${q(def.key)} = ? AND "version" = ?`)
                        .run(...names.map((n) => encode(def.fields[n], patch[n])), key, expect_version);
                    if (res.changes === 0) throw new Conflict(`${kind} ${key} is not at version ${expect_version}`);
                }
                let logSeq = null;
                for (const entry of log) {
                    const names = Object.keys(entry);
                    logSeq = Number(db.prepare(`INSERT INTO log (${names.map(q).join(', ')}) VALUES (${names.map(() => '?').join(', ')})`)
                        .run(...names.map((n) => encode(LOG_FIELDS[n], entry[n]))).lastInsertRowid);
                }
                return { seqs, log_seq: logSeq };
            }));
        },

        async logSince(seq, limit) {
            return guarded(() => db.prepare('SELECT * FROM log WHERE "seq" > ? ORDER BY "seq" LIMIT ?').all(seq, limit)
                .map((raw) => fullLog(raw.seq, decode(LOG_FIELDS, raw))));
        },
        async logOf(refs) {
            if (!refs.length) return [];
            return guarded(() => db.prepare(`SELECT * FROM log WHERE "ref" IN (${refs.map(() => '?').join(', ')}) ORDER BY "seq"`).all(...refs)
                .map((raw) => fullLog(raw.seq, decode(LOG_FIELDS, raw))));
        },
    };
}
