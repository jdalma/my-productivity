/**
 * The board store contract (T63a). Core owns the shape of every row (KINDS)
 * and the errors; an adapter imports this file only, stores rows of these shapes and throws these errors.
 * The checks below are shared so every adapter accepts and refuses the same rows.
 *
 * A store is an object with these async methods:
 *   open()                      make the store usable; create or migrate its schema. Safe to call again and
 *                               from several processes at once. A schema newer than SCHEMA_VERSION: SchemaTooNew
 *   close()                     release it; safe to call twice
 *   describe()                  { adapter, schema_version, location, board_id }; board_id is made once when
 *                               the store is created, so a reader can tell a new board from an old one (R69 R2)
 *   get(kind, key)              the row, or null
 *   list(kind, where, order?)   rows matching every `field: value` on filterable fields (and the key). A value
 *                               must fit the field's type; null matches no value; a value list matches any of
 *                               its values (null among them included); an empty list matches nothing.
 *                               order is [field, 'asc'|'desc'], by key when left out; ties go by key, ascending;
 *                               null is smaller than any value; text compares by Unicode code point
 *   apply({creates, updates, log})
 *                               all or nothing. creates: [{kind, row}]; a key that exists is a Conflict.
 *                               updates: [{kind, key, expect_version, patch}]; applied only while the row's
 *                               version equals expect_version, which then goes up by one; otherwise Conflict.
 *                               An update names a row that existed before the change set (InvalidRow for one
 *                               created in it). A lost lock race (a deadlock, a serialization failure) is a
 *                               Conflict too.
 *                               log: [entry], numbered in commit order.
 *                               Returns { seqs: {<kind>: [new seq…]}, log_seq } (log_seq null with no log)
 *   logSince(seq, limit)        log entries after seq, oldest first
 * Rows read back with every field of their kind (null when unset), plus `version` on versioned kinds.
 * A store does not check references between rows (a landing's task, a finding's verdict): core keeps them,
 * in the same change set.
 */

export const SCHEMA_VERSION = 3;

const text = (opts = {}) => ({ type: 'text', ...opts });
const int = (opts = {}) => ({ type: 'int', ...opts });
const list = (opts = {}) => ({ type: 'list', ...opts });
const req = { required: true };
const filt = { filterable: true };
const created = { created_at: text(req), created_by: text(req) };
const updated = { updated_at: text(), updated_by: text() };

/**
 * key: the key field. seq: the store numbers the key. versioned: rows take updates (and carry `version`);
 * the others are written once.
 */
export const KINDS = {
    task: {
        key: 'id', seq: false, versioned: true,
        fields: {
            id: text(req), parent_id: text(filt), title: text(req), ticket_path: text(),
            state: text({ ...req, ...filt }), assignee: text(filt), reviewer: text(filt),
            priority: int({ ...req, ...filt }), base_commit: text(), constraints: text(), assigned_at: text(),
            ...created, ...updated,
        },
    },
    landing: {
        key: 'id', seq: false, versioned: true,
        fields: {
            id: text(req), task_id: text({ ...req, ...filt }), repo: text({ ...req, ...filt }),
            commit: text({ ...req, ...filt }), base_commit: text(req), commits: list(req), check_cmd: text(req),
            check_result: text(req), focus: list(req), closes: list(req), report_path: text(req),
            // review_report_path is the reviewer's to choose; a land may suggest one (R71 R2, schema 3)
            review_report_path: text(), deployed: text(), superseded_by: text(filt),
            left_out: list(),   // rev-list commits the landing leaves out (R69 R3); null on rows before schema 2
            ...created, ...updated,
        },
    },
    verdict: {
        key: 'id', seq: false, versioned: false,
        fields: {
            id: text(req), landing_id: text({ ...req, ...filt }), verdict: text({ ...req, ...filt }),
            verified_commit: text(req), report_path: text(req), rerun_cmd: text(req), rerun_result: text(req),
            side_notes: text(),
            ...created,
        },
    },
    finding: {
        key: 'id', seq: false, versioned: true,
        fields: {
            id: text(req), verdict_id: text({ ...req, ...filt }), task_id: text({ ...req, ...filt }),
            severity: text({ ...req, ...filt }), summary: text(req), repro: text(req),
            state: text({ ...req, ...filt }), fixed_in: text(filt),
            ...created, ...updated,
        },
    },
    note: {
        key: 'seq', seq: true, versioned: false,
        fields: { seq: int(), task_id: text(filt), body: text(req), to: list(), ...created },
    },
    announcement: {
        key: 'seq', seq: true, versioned: false,
        fields: { seq: int(), body: text(req), ...created },
    },
};

export const LOG_FIELDS = {
    at: text(req), actor: text(req), action: text(req), kind: text(req), ref: text(req),
    state_from: text(), state_to: text(), detail: { type: 'json' },
};

export class StoreError extends Error {
    constructor(message, code = 'store') {
        super(message);
        this.name = new.target.name;
        this.code = code;
    }
}
export class Conflict extends StoreError { constructor(m) { super(m, 'conflict'); } }
export class Busy extends StoreError { constructor(m) { super(m, 'busy'); } }
export class SchemaTooNew extends StoreError { constructor(m) { super(m, 'schema-too-new'); } }
export class InvalidQuery extends StoreError { constructor(m) { super(m, 'invalid-query'); } }
export class InvalidRow extends StoreError { constructor(m) { super(m, 'invalid-row'); } }
/** The store cannot run here at all (a Node without its driver): every board command fails, the rest of my-team runs. */
export class Unavailable extends StoreError { constructor(m) { super(m, 'board-unavailable'); } }

const isPlainObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v)
    && (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);

/** Values that survive JSON text unchanged: what every store can keep. */
function plainJson(v) {
    if (v === null || typeof v === 'string' || typeof v === 'boolean') return true;
    if (typeof v === 'number') return Number.isFinite(v);
    if (Array.isArray(v)) return v.every(plainJson);
    return isPlainObject(v) && Object.values(v).every(plainJson);
}

function fits(spec, value) {
    if (value === null) return true;
    switch (spec.type) {
        case 'text': return typeof value === 'string';
        case 'int': return Number.isInteger(value);
        case 'list': return Array.isArray(value) && value.every((v) => typeof v === 'string');
        case 'json': return isPlainObject(value) && plainJson(value);
    }
    return false;
}

function checkFields(where, fields, values, { all }) {
    for (const [name, value] of Object.entries(values)) {
        const spec = fields[name];
        if (!spec) throw new InvalidRow(`${where}: no field '${name}'`);
        if (value === undefined || !fits(spec, value)) throw new InvalidRow(`${where}: '${name}' must be ${spec.type}`);
        if (spec.required && value === null) throw new InvalidRow(`${where}: '${name}' is required`);
    }
    if (all) {
        for (const [name, spec] of Object.entries(fields)) {
            if (spec.required && !(name in values)) throw new InvalidRow(`${where}: '${name}' is required`);
        }
    }
}

export function kindOf(kind, Err = InvalidRow) {
    const def = Object.hasOwn(KINDS, kind) ? KINDS[kind] : null;
    if (!def) throw new Err(`no kind '${kind}'`);
    return def;
}

/** A full row of `kind` with every field (null when unset) — what a store hands back. */
export function fullRow(kind, row) {
    const def = KINDS[kind];
    const out = {};
    for (const name of Object.keys(def.fields)) out[name] = row[name] ?? null;
    if (def.versioned) out.version = row.version;
    return structuredClone(out);
}

/**
 * Checks a change set before a store applies any of it. A patch may not set the key, version or creation
 * fields, nor clear a required field, nor name a row the same change set creates. A seq kind's key is not a
 * field of its create, so a row that brings one is refused like any unknown field. JSON values must be plain
 * (what survives JSON text), so no store fails half way through writing one.
 */
export function checkChanges({ creates = [], updates = [], log = [] } = {}) {
    for (const { kind, row } of creates) {
        const def = kindOf(kind);
        if (!row || typeof row !== 'object') throw new InvalidRow(`create ${kind}: no row`);
        const fields = def.seq ? Object.fromEntries(Object.entries(def.fields).filter(([n]) => n !== def.key)) : def.fields;
        checkFields(`create ${kind}`, fields, row, { all: true });
    }
    const created = new Set(creates.filter(({ kind }) => !KINDS[kind].seq).map(({ kind, row }) => `${kind}\0${row[KINDS[kind].key]}`));
    for (const { kind, key, expect_version, patch } of updates) {
        const def = kindOf(kind);
        if (created.has(`${kind}\0${key}`)) throw new InvalidRow(`update ${kind} ${key}: created in the same change set; write it whole`);
        if (!def.versioned) throw new InvalidRow(`${kind} rows are written once`);
        if (!Number.isInteger(expect_version)) throw new InvalidRow(`update ${kind} ${key}: expect_version must be an integer`);
        for (const name of Object.keys(patch ?? {})) {
            if (name === def.key || name === 'created_at' || name === 'created_by') {
                throw new InvalidRow(`update ${kind} ${key}: '${name}' cannot change`);
            }
        }
        checkFields(`update ${kind} ${key}`, def.fields, patch ?? {}, { all: false });
    }
    for (const entry of log) checkFields('log', LOG_FIELDS, entry ?? {}, { all: true });
}

/** Checks a get() key against the kind's key field. */
export function checkKey(kind, key) {
    const def = kindOf(kind, InvalidQuery);
    const spec = def.fields[def.key];
    if (key === undefined || key === null || !fits(spec, key)) throw new InvalidQuery(`${kind}: the key '${def.key}' is ${spec.type}`);
    return def;
}

/** Checks list() arguments; returns the order as [field, direction]. */
export function checkQuery(kind, where = {}, order) {
    const def = kindOf(kind, InvalidQuery);
    const usable = (name) => name === def.key || def.fields[name]?.filterable;
    for (const [name, want] of Object.entries(where)) {
        if (!usable(name)) throw new InvalidQuery(`${kind}: '${name}' is not filterable`);
        const values = Array.isArray(want) ? want : [want];
        if (values.some((v) => v === undefined || !fits(def.fields[name], v))) {
            throw new InvalidQuery(`${kind}: '${name}' takes ${def.fields[name].type} values or null`);
        }
    }
    if (!order) return [def.key, 'asc'];
    const [field, dir] = order;
    if (!usable(field)) throw new InvalidQuery(`${kind}: cannot order by '${field}'`);
    if (dir !== 'asc' && dir !== 'desc') throw new InvalidQuery(`${kind}: order must be 'asc' or 'desc'`);
    return [field, dir];
}

/** A full log entry as a store hands it back. */
export function fullLog(seq, entry) {
    const out = { seq };
    for (const name of Object.keys(LOG_FIELDS)) out[name] = entry[name] ?? null;
    return structuredClone(out);
}
