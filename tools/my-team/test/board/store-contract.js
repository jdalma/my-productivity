/**
 * The board store contract as tests (T63a, rfc/board-design.md §4): an adapter that passes runStoreContract
 * can replace any other. Each adapter's test file calls it with a factory that returns a fresh, unopened store.
 * Cross-process concurrency is adapter-specific (memory is not shared between processes) and lives with the
 * adapter that has it. A store that keeps a schema passes makeNewerStore: a store over data written by a newer
 * schema, which open() must refuse. skip (a reason) skips the whole bundle, for a store this Node cannot run.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { KINDS, SCHEMA_VERSION, StoreError } from '../../src/board/core/contract.js';

const AT = '2026-11-11T08:00:00.000Z';

const task = (id, extra = {}) => ({
    id, title: `title ${id}`, state: 'new', priority: 100, created_at: AT, created_by: 'pm', ...extra,
});
const logEntry = (ref, extra = {}) => ({ at: AT, actor: 'pm', action: 'add', kind: 'task', ref, ...extra });
const landing = (id, extra = {}) => ({
    id, task_id: 'T1', repo: '/repo', commit: 'a'.repeat(40), base_commit: 'b'.repeat(40),
    commits: ['a'.repeat(40)], check_cmd: 'npm test',
    check_result: '10/10', focus: ['one'], closes: [], report_path: '/r/T1.md', review_report_path: '/r/R1.md',
    created_at: AT, created_by: 'core', ...extra,
});

async function rejectsWith(promise, code) {
    await assert.rejects(promise, (err) => {
        assert.ok(err instanceof StoreError, `a StoreError, got ${err?.constructor?.name}: ${err?.message}`);
        assert.equal(err.code, code, err.message);
        return true;
    });
}

export function runStoreContract(name, makeStore, { makeNewerStore, skip } = {}) {
    const withStore = (title, fn) => test(`[${name}] ${title}`, { skip: skip ?? false }, async (t) => {
        const store = await makeStore(t);
        await store.open();
        t.after(() => store.close());
        await fn(store, t);
    });

    withStore('open twice is harmless, and describe names the adapter and schema version', async (store) => {
        await store.open();
        const d = await store.describe();
        assert.equal(d.adapter, name);
        assert.equal(d.schema_version, SCHEMA_VERSION);
        assert.ok('location' in d);
    });

    withStore('a created row reads back with every field, version 1, and lists intact', async (store) => {
        await store.apply({ creates: [{ kind: 'task', row: task('T1', { constraints: 'tmux -L only' }) }], log: [logEntry('T1')] });
        const row = await store.get('task', 'T1');
        assert.deepEqual(Object.keys(row).sort(), [...Object.keys(KINDS.task.fields), 'version'].sort());
        assert.equal(row.version, 1);
        assert.equal(row.constraints, 'tmux -L only');
        assert.equal(row.parent_id, null, 'a field left out reads back as null');
        await store.apply({ creates: [{ kind: 'landing', row: landing('T1#1', { focus: ['a', 'b'], closes: ['R1 M1'] }) }] });
        const l = await store.get('landing', 'T1#1');
        assert.deepEqual([l.focus, l.closes], [['a', 'b'], ['R1 M1']]);
    });

    withStore('rows handed in and out are copies', async (store) => {
        const row = landing('T1#1');
        await store.apply({ creates: [{ kind: 'landing', row }] });
        row.focus.push('changed after apply');
        const read = await store.get('landing', 'T1#1');
        read.focus.push('changed after get');
        assert.deepEqual((await store.get('landing', 'T1#1')).focus, ['one']);
    });

    withStore('get of a missing key is null', async (store) => {
        assert.equal(await store.get('task', 'nope'), null);
    });

    withStore('get refuses a key of the wrong type', async (store) => {
        const { seqs } = await store.apply({ creates: [{ kind: 'note', row: { body: 'b', created_at: AT, created_by: 'pm' } }] });
        assert.equal((await store.get('note', seqs.note[0])).body, 'b');
        await rejectsWith(store.get('note', String(seqs.note[0])), 'invalid-query');
        await rejectsWith(store.get('task', 1), 'invalid-query');
        await rejectsWith(store.get('task', undefined), 'invalid-query');
        await rejectsWith(store.get('nothing', 'x'), 'invalid-query');
    });

    withStore('a row missing a required field, with an unknown field or a wrong type is refused, and nothing is stored', async (store) => {
        const { title, ...noTitle } = task('T1');
        await rejectsWith(store.apply({ creates: [{ kind: 'task', row: noTitle }] }), 'invalid-row');
        await rejectsWith(store.apply({ creates: [{ kind: 'task', row: task('T1', { colour: 'red' }) }] }), 'invalid-row');
        await rejectsWith(store.apply({ creates: [{ kind: 'task', row: task('T1', { priority: '1' }) }] }), 'invalid-row');
        await rejectsWith(store.apply({ creates: [{ kind: 'landing', row: landing('T1#1', { focus: 'one' }) }] }), 'invalid-row');
        await rejectsWith(store.apply({ creates: [{ kind: 'nothing', row: {} }] }), 'invalid-row');
        assert.deepEqual(await store.list('task', {}), []);
        assert.deepEqual(await store.list('landing', {}), []);
    });

    withStore('a key that exists is a conflict, and the whole change set is dropped', async (store) => {
        await store.apply({ creates: [{ kind: 'task', row: task('T1') }] });
        await rejectsWith(store.apply({
            creates: [{ kind: 'task', row: task('T2') }, { kind: 'task', row: task('T1') }],
            log: [logEntry('T2')],
        }), 'conflict');
        assert.equal(await store.get('task', 'T2'), null);
        assert.deepEqual(await store.logSince(0, 10), []);
    });

    withStore('the store numbers seq kinds in order and refuses a seq handed in', async (store) => {
        const note = (body) => ({ kind: 'note', row: { body, created_at: AT, created_by: 'core' } });
        const a = await store.apply({ creates: [note('one'), note('two')] });
        const b = await store.apply({ creates: [note('three')] });
        const seqs = [...a.seqs.note, ...b.seqs.note];
        assert.deepEqual(seqs, [...seqs].sort((x, y) => x - y));
        assert.equal(new Set(seqs).size, 3);
        assert.equal((await store.get('note', seqs[2])).body, 'three');
        await rejectsWith(store.apply({ creates: [{ kind: 'note', row: { seq: 99, body: 'x', created_at: AT, created_by: 'core' } }] }), 'invalid-row');
    });

    withStore('an update applies at the expected version only, and raises the version', async (store) => {
        await store.apply({ creates: [{ kind: 'task', row: task('T1') }] });
        await store.apply({ updates: [{ kind: 'task', key: 'T1', expect_version: 1, patch: { state: 'ready', assignee: 'core' } }] });
        const row = await store.get('task', 'T1');
        assert.deepEqual([row.state, row.assignee, row.title, row.version], ['ready', 'core', 'title T1', 2]);
        await rejectsWith(store.apply({ updates: [{ kind: 'task', key: 'T1', expect_version: 1, patch: { state: 'doing' } }] }), 'conflict');
        await rejectsWith(store.apply({ updates: [{ kind: 'task', key: 'T9', expect_version: 1, patch: { state: 'doing' } }] }), 'conflict');
        assert.equal((await store.get('task', 'T1')).state, 'ready');
    });

    withStore('a patch may not touch the key, version or creation fields, nor name unknown fields; append-only kinds take no updates', async (store) => {
        await store.apply({ creates: [{ kind: 'task', row: task('T1') }] });
        const up = (kind, key, patch) => store.apply({ updates: [{ kind, key, expect_version: 1, patch }] });
        for (const patch of [{ id: 'T2' }, { version: 5 }, { created_by: 'x' }, { colour: 'red' }, { title: null }]) {
            await rejectsWith(up('task', 'T1', patch), 'invalid-row');
        }
        const { seqs } = await store.apply({ creates: [{ kind: 'note', row: { body: 'b', created_at: AT, created_by: 'pm' } }] });
        await rejectsWith(up('note', seqs.note[0], { body: 'c' }), 'invalid-row');
        assert.equal((await store.get('task', 'T1')).version, 1);
    });

    withStore('a change set is all or nothing: a stale update drops the creates and the log beside it', async (store) => {
        await store.apply({ creates: [{ kind: 'task', row: task('T1') }], log: [logEntry('T1')] });
        await rejectsWith(store.apply({
            creates: [{ kind: 'landing', row: landing('T1#1') }],
            updates: [{ kind: 'task', key: 'T1', expect_version: 7, patch: { state: 'review' } }],
            log: [logEntry('T1', { action: 'land' })],
        }), 'conflict');
        assert.equal(await store.get('landing', 'T1#1'), null);
        assert.equal((await store.logSince(0, 10)).length, 1);
        await store.apply({ creates: [{ kind: 'task', row: task('T2') }] });
        await rejectsWith(store.apply({ updates: [
            { kind: 'task', key: 'T1', expect_version: 1, patch: { state: 'ready' } },
            { kind: 'task', key: 'T2', expect_version: 9, patch: { state: 'ready' } },
        ] }), 'conflict');
        assert.deepEqual([(await store.get('task', 'T1')).state, (await store.get('task', 'T1')).version], ['new', 1]);
    });

    withStore('one change set can create a row and point another row at it', async (store) => {
        await store.apply({ creates: [
            { kind: 'task', row: task('T1') },
            { kind: 'finding', row: { id: 'R1 M1', verdict_id: 'R1', task_id: 'T1', severity: 'must', summary: 's', repro: 'r', state: 'open', created_at: AT, created_by: 'rv' } },
        ] });
        await store.apply({
            creates: [{ kind: 'landing', row: landing('T1#1', { closes: ['R1 M1'] }) }],
            updates: [{ kind: 'finding', key: 'R1 M1', expect_version: 1, patch: { state: 'fixed', fixed_in: 'T1#1' } }],
        });
        assert.equal((await store.get('finding', 'R1 M1')).fixed_in, 'T1#1');
    });

    withStore('list filters by equality, by a set of values and by null, and orders by one field with ties by key', async (store) => {
        await store.apply({ creates: [
            { kind: 'task', row: task('T1', { assignee: 'core', priority: 30 }) },
            { kind: 'task', row: task('T2', { assignee: 'app', priority: 10, state: 'doing' }) },
            { kind: 'task', row: task('T3', { priority: 20 }) },
        ] });
        const ids = (rows) => rows.map((r) => r.id);
        assert.deepEqual(ids(await store.list('task', {})), ['T1', 'T2', 'T3'], 'by key when no order is given');
        assert.deepEqual(ids(await store.list('task', { assignee: 'core' })), ['T1']);
        assert.deepEqual(ids(await store.list('task', { assignee: ['core', 'app'] })), ['T1', 'T2']);
        assert.deepEqual(ids(await store.list('task', { assignee: null })), ['T3']);
        assert.deepEqual(ids(await store.list('task', { assignee: ['app', null] })), ['T2', 'T3'], 'null in a value list matches no value');
        assert.deepEqual(ids(await store.list('task', { state: 'new', assignee: 'core' })), ['T1']);
        assert.deepEqual(ids(await store.list('task', {}, ['priority', 'asc'])), ['T2', 'T3', 'T1']);
        assert.deepEqual(ids(await store.list('task', {}, ['priority', 'desc'])), ['T1', 'T3', 'T2']);
        assert.deepEqual(ids(await store.list('task', { assignee: [] })), []);
        await store.apply({ creates: [{ kind: 'task', row: task('T5', { priority: 20 }) }, { kind: 'task', row: task('T4', { priority: 20 }) }] });
        assert.deepEqual(ids(await store.list('task', { priority: 20 }, ['priority', 'desc'])), ['T3', 'T4', 'T5'], 'ties by key, ascending');
    });

    withStore('list refuses values that do not fit the field, and undefined', async (store) => {
        await rejectsWith(store.list('task', { priority: '20' }), 'invalid-query');
        await rejectsWith(store.list('task', { priority: [20, '30'] }), 'invalid-query');
        await rejectsWith(store.list('task', { assignee: undefined }), 'invalid-query');
        await rejectsWith(store.list('task', { assignee: [1] }), 'invalid-query');
        await rejectsWith(store.list('task', { assignee: [undefined] }), 'invalid-query');
    });

    withStore('text orders by Unicode code point', async (store) => {
        // UTF-16 puts the emoji (a surrogate pair, 0xD83D…) before U+FFFD; by code point it comes after
        await store.apply({ creates: [{ kind: 'task', row: task('a\u{1F600}') }, { kind: 'task', row: task('a\uFFFD') }, { kind: 'task', row: task('aZ') }] });
        assert.deepEqual((await store.list('task', {})).map((r) => r.id), ['aZ', 'a\uFFFD', 'a\u{1F600}']);
    });

    withStore('list refuses fields that are not filterable, and bad orders', async (store) => {
        await rejectsWith(store.list('task', { title: 'x' }), 'invalid-query');
        await rejectsWith(store.list('task', { colour: 'x' }), 'invalid-query');
        await rejectsWith(store.list('task', {}, ['title', 'asc']), 'invalid-query');
        await rejectsWith(store.list('task', {}, ['priority', 'sideways']), 'invalid-query');
        await rejectsWith(store.list('nothing', {}), 'invalid-query');
    });

    withStore('log entries are numbered in commit order and read back from a seq', async (store) => {
        const a = await store.apply({ creates: [{ kind: 'task', row: task('T1') }], log: [logEntry('T1')] });
        const b = await store.apply({
            updates: [{ kind: 'task', key: 'T1', expect_version: 1, patch: { state: 'ready' } }],
            log: [logEntry('T1', { action: 'assign', state_from: 'new', state_to: 'ready', detail: { assignee: 'core' } }), logEntry('T1', { action: 'note' })],
        });
        assert.ok(b.log_seq > a.log_seq);
        const all = await store.logSince(0, 10);
        assert.deepEqual(all.map((e) => e.action), ['add', 'assign', 'note']);
        assert.deepEqual(all.map((e) => e.seq), [...all.map((e) => e.seq)].sort((x, y) => x - y));
        assert.equal(all[2].seq, b.log_seq);
        assert.deepEqual(all[1].detail, { assignee: 'core' });
        assert.equal(all[0].state_to, null);
        assert.deepEqual((await store.logSince(all[0].seq, 1)).map((e) => e.action), ['assign']);
        assert.equal((await store.apply({ creates: [{ kind: 'task', row: task('T2') }] })).log_seq, null);
    });

    withStore('a store does not check references between rows: core keeps them', async (store) => {
        await store.apply({ creates: [
            { kind: 'landing', row: landing('T9#1', { task_id: 'T9' }) },
            { kind: 'finding', row: { id: 'R9 M1', verdict_id: 'R9', task_id: 'T9', severity: 'low', summary: 's', repro: 'r', state: 'open', created_at: AT, created_by: 'rv' } },
        ] });
        assert.equal((await store.get('landing', 'T9#1')).task_id, 'T9');
        assert.equal(await store.get('task', 'T9'), null);
    });

    withStore('a JSON value that JSON text would change is refused before anything is written', async (store) => {
        for (const detail of [{ f: () => 1 }, { when: new Date(0) }, { n: NaN }, { deep: [{ u: undefined }] }, new Map()]) {
            await rejectsWith(store.apply({ creates: [{ kind: 'task', row: task('T1') }], log: [logEntry('T1', { detail })] }), 'invalid-row');
        }
        assert.equal(await store.get('task', 'T1'), null);
        assert.deepEqual(await store.logSince(0, 10), []);
    });

    withStore('an update may not name a row created in the same change set', async (store) => {
        await rejectsWith(store.apply({
            creates: [{ kind: 'task', row: task('T1') }],
            updates: [{ kind: 'task', key: 'T1', expect_version: 1, patch: { state: 'ready' } }],
        }), 'invalid-row');
        assert.equal(await store.get('task', 'T1'), null);
    });

    withStore('a log entry missing a field is refused with the change set', async (store) => {
        const { actor, ...noActor } = logEntry('T1');
        await rejectsWith(store.apply({ creates: [{ kind: 'task', row: task('T1') }], log: [noActor] }), 'invalid-row');
        assert.equal(await store.get('task', 'T1'), null);
    });

    withStore('two updates of one row at the same version: exactly one wins', async (store) => {
        await store.apply({ creates: [{ kind: 'task', row: task('T1') }] });
        const race = (who) => store.apply({ updates: [{ kind: 'task', key: 'T1', expect_version: 1, patch: { assignee: who } }] });
        const results = await Promise.allSettled([race('a'), race('b'), race('c')]);
        assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
        for (const r of results.filter((x) => x.status === 'rejected')) assert.equal(r.reason.code, 'conflict');
        const row = await store.get('task', 'T1');
        assert.equal(row.version, 2);
    });

    withStore('updates of different rows do not conflict', async (store) => {
        await store.apply({ creates: [{ kind: 'task', row: task('T1') }, { kind: 'task', row: task('T2') }] });
        const up = (key) => store.apply({ updates: [{ kind: 'task', key, expect_version: 1, patch: { state: 'ready' } }] });
        await Promise.all([up('T1'), up('T2')]);
        assert.deepEqual((await store.list('task', { state: 'ready' })).map((r) => r.id), ['T1', 'T2']);
    });

    test(`[${name}] a store over data from a newer schema refuses to open`, { skip: skip ?? (makeNewerStore ? false : 'this store keeps no schema') }, async (t) => {
        const store = await makeNewerStore(t);
        t.after(() => store.close());
        await rejectsWith(store.open(), 'schema-too-new');
    });
}
