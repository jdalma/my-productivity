/**
 * The board store in memory (T63a): the second adapter, kept so the contract cannot lean on SQLite, and the
 * store for core's tests. One process only; nothing is kept after it ends. apply() checks everything and
 * copies every row before it changes anything, then changes them without awaiting, so a change set is all or
 * nothing.
 */

import { randomUUID } from 'node:crypto';

import {
    KINDS, SCHEMA_VERSION, Conflict, checkChanges, checkKey, checkQuery, fullLog, fullRow,
} from '../../core/contract.js';

/** The contract's order: null first, text by Unicode code point (JS < compares UTF-16 units). */
function compare(a, b) {
    if (a === b) return 0;
    if (a === null) return -1;
    if (b === null) return 1;
    if (typeof a === 'string') {
        const x = [...a], y = [...b];
        for (let i = 0; i < Math.min(x.length, y.length); i++) {
            if (x[i] !== y[i]) return x[i].codePointAt(0) < y[i].codePointAt(0) ? -1 : 1;
        }
        return x.length < y.length ? -1 : 1;
    }
    return a < b ? -1 : 1;
}

export function createMemoryStore() {
    const tables = Object.fromEntries(Object.keys(KINDS).map((k) => [k, new Map()]));
    const seqs = Object.fromEntries(Object.keys(KINDS).map((k) => [k, 0]));
    const log = [];
    const boardId = randomUUID().replaceAll('-', '');

    return {
        async open() {},
        async close() {},
        async describe() {
            return { adapter: 'memory', schema_version: SCHEMA_VERSION, location: null, board_id: boardId };
        },

        async get(kind, key) {
            checkKey(kind, key);
            const row = tables[kind].get(key);
            return row ? fullRow(kind, row) : null;
        },

        async list(kind, where = {}, order) {
            const [field, dir] = checkQuery(kind, where, order);
            const key = KINDS[kind].key;
            const match = (row) => Object.entries(where).every(([name, want]) => {
                const have = row[name] ?? null;
                return Array.isArray(want) ? want.includes(have) : have === want;
            });
            const sign = dir === 'asc' ? 1 : -1;
            return [...tables[kind].values()]
                .filter(match)
                .sort((a, b) => sign * compare(a[field] ?? null, b[field] ?? null) || compare(a[key], b[key]))
                .map((row) => fullRow(kind, row));
        },

        async apply(changes = {}) {
            checkChanges(changes);
            const { creates = [], updates = [], log: entries = [] } = changes;
            const newKeys = new Set();
            for (const { kind, row } of creates) {
                const def = KINDS[kind];
                if (def.seq) continue;
                const id = `${kind}\0${row[def.key]}`;
                if (tables[kind].has(row[def.key]) || newKeys.has(id)) throw new Conflict(`${kind} ${row[def.key]} exists`);
                newKeys.add(id);
            }
            const seen = new Map();
            for (const { kind, key, expect_version } of updates) {
                const row = tables[kind].get(key);
                const id = `${kind}\0${key}`;
                const version = seen.get(id) ?? row?.version;
                if (version !== expect_version) {
                    throw new Conflict(`${kind} ${key} is at version ${version ?? 'none'}, not ${expect_version}`);
                }
                seen.set(id, version + 1);
            }

            const made = {};
            const next = { ...seqs };
            const rows = creates.map(({ kind, row }) => {
                const def = KINDS[kind];
                const stored = structuredClone(row);
                if (def.seq) {
                    stored[def.key] = ++next[kind];
                    (made[kind] ??= []).push(stored[def.key]);
                }
                if (def.versioned) stored.version = 1;
                return { kind, stored };
            });
            const patches = updates.map(({ kind, key, patch }) => ({ kind, key, patch: structuredClone(patch) }));
            const entriesOut = entries.map((entry, i) => fullLog(log.length + 1 + i, entry));

            Object.assign(seqs, next);
            for (const { kind, stored } of rows) tables[kind].set(stored[KINDS[kind].key], stored);
            for (const { kind, key, patch } of patches) {
                const row = tables[kind].get(key);
                Object.assign(row, patch, { version: row.version + 1 });
            }
            log.push(...entriesOut);
            return { seqs: made, log_seq: entries.length ? log.length : null };
        },

        async logSince(seq, limit) {
            return log.filter((e) => e.seq > seq).slice(0, limit).map((e) => structuredClone(e));
        },
    };
}
