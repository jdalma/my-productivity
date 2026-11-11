/**
 * The board store in memory (T63a): the second adapter, kept so the contract cannot lean on SQLite, and the
 * store for core's tests. One process only; nothing is kept after it ends. apply() checks everything before
 * it changes anything and then runs without awaiting, so a change set is all or nothing.
 */

import {
    KINDS, SCHEMA_VERSION, Conflict, checkChanges, checkQuery, fullLog, fullRow, kindOf,
} from '../../core/contract.js';

function compare(a, b) {
    if (a === b) return 0;
    if (a === null) return -1;
    if (b === null) return 1;
    return a < b ? -1 : 1;
}

export function createMemoryStore() {
    const tables = Object.fromEntries(Object.keys(KINDS).map((k) => [k, new Map()]));
    const seqs = Object.fromEntries(Object.keys(KINDS).map((k) => [k, 0]));
    const log = [];

    return {
        async open() {},
        async close() {},
        async describe() {
            return { adapter: 'memory', schema_version: SCHEMA_VERSION, location: null };
        },

        async get(kind, key) {
            kindOf(kind);
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
            for (const { kind, row } of creates) {
                const def = KINDS[kind];
                const stored = structuredClone(row);
                if (def.seq) {
                    stored[def.key] = ++seqs[kind];
                    (made[kind] ??= []).push(stored[def.key]);
                }
                if (def.versioned) stored.version = 1;
                tables[kind].set(stored[def.key], stored);
            }
            for (const { kind, key, patch } of updates) {
                const row = tables[kind].get(key);
                Object.assign(row, structuredClone(patch), { version: row.version + 1 });
            }
            for (const entry of entries) log.push(fullLog(log.length + 1, entry));
            return { seqs: made, log_seq: entries.length ? log.length : null };
        },

        async logSince(seq, limit) {
            return log.filter((e) => e.seq > seq).slice(0, limit).map((e) => structuredClone(e));
        },
    };
}
