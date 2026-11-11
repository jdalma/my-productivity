/**
 * The board's write commands (T63c) on every store (memory and, where node:sqlite runs, SQLite): every row of the transition tables
 * (rfc/board-design.md §3.1, §3.2), the id rules (§2.8), the lock table (§4.1) and the notices (§6.2).
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { createBoard } from '../../src/board/core/service.js';
import { nextLetters } from '../../src/board/core/rules.js';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { createMemoryStore } from '../../src/board/store/memory/index.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';

const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const STORES = {
    memory: async () => createMemoryStore(),
    sqlite: async (t) => {
        const dir = mkdtempSync(join(tmpdir(), 'mt-board-svc-'));
        const store = createSqliteStore(join(dir, 'board.db'));
        await store.open();
        t.after(async () => { await store.close(); rmSync(dir, { recursive: true, force: true }); });
        return store;
    },
};

/** Registers the test once per store; fn gets setup(options) bound to that store. */
function both(name, fn) {
    for (const [kind, make] of Object.entries(STORES)) {
        const skip = kind === 'sqlite' && !hasSqlite ? 'node:sqlite needs Node >= 22.13' : false;
        test(`[${kind}] ${name}`, { skip }, (t) => fn((options) => setup(options, () => make(t))));
    }
}

const ROSTER = [
    { name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' },
    { name: 'app', role: 'worker' }, { name: 'rv', role: 'worker' },
];
const H = (c) => c.repeat(40);
const BASE = H('0');

async function setup({ roster = ROSTER } = {}, makeStore) {
    const store = await makeStore();
    let tick = 0;
    const now = () => new Date(Date.UTC(2026, 10, 11, 0, 0, tick++)).toISOString();
    const sent = [], events = [];
    const ranges = new Map();
    const git = { range: async (repo, base, commit) => ranges.get(`${base}..${commit}`) ?? { ancestor: true, commits: [commit] } };
    const as = (actor, over = {}) => createBoard({
        store: over.store ?? store, roster: () => roster, actor, now, git,
        notify: over.notify ?? (async (to, ref, action) => { sent.push({ to: [...to].sort(), ref, action }); return []; }),
        event: async (e) => { events.push(e); return true; },
    });
    return { store, as, sent, events, ranges };
}

async function rejects(promise, code) {
    await assert.rejects(promise, (err) => { assert.equal(err.code, code, err.message); return true; });
}

const land = (id, commit, extra = {}) => ({
    id, repo: '/repo', commit, check: { cmd: 'npm test', result: '1/1' }, focus: ['one'], closes: [],
    report: '/r/c.md', review_report: '/r/R.md', ...extra,
});
const judge = (landing, commit, verdict, extra = {}) => ({
    landing, verdict, verified_commit: commit, report: '/r/R.md', rerun: { cmd: 'npm test', result: '1/1' }, findings: [], ...extra,
});
const must = (code) => ({ code, severity: 'must', summary: 's', repro: 'r' });

/** A task T1 for core, reviewed by rv, in `state`. */
async function taskIn(b, state, { reviewer = 'rv', id = 'T1' } = {}) {
    await b.as('pm').add({ id, title: 't', assignee: 'core', reviewer, base: BASE });
    if (state === 'ready') return;
    await b.as('core').take({ id });
    if (state === 'doing') return;
    await b.as('core').land(land(id, H('1')));
    if (state === 'review') return;
    const v = { done: 'approve', changes: 'changes', held: 'hold' }[state];
    await b.as(reviewer ?? 'pm').verdict(judge(`${id}#1`, H('1'), v, v === 'changes' ? { findings: [must('M1')] } : {}));
}

/** A store whose next `times` applies first run `during` (another command between read and write). */
function interleave(store, during, times = 1) {
    const proxy = { ...store, conflicts: 0 };
    proxy.apply = async (changes) => {
        if (proxy.left-- > 0) await during();
        try { return await store.apply(changes); } catch (err) { if (err.code === 'conflict') proxy.conflicts++; throw err; }
    };
    proxy.left = times;
    return proxy;
}

/** A store that records the rows each apply puts a version condition on. */
function recording(store) {
    const proxy = { ...store, locked: [] };
    proxy.apply = async (changes) => {
        proxy.locked.push((changes.updates ?? []).map((u) => `${u.kind} ${u.key}`).sort());
        return store.apply(changes);
    };
    return proxy;
}

// §3.1 — tasks

both('add: a task without an assignee is new, with one ready and the assignee is told; only pm adds', async (setup) => {
    const b = await setup();
    assert.equal((await b.as('pm').add({ title: 'a' })).task.state, 'new');
    const r = await b.as('pm').add({ title: 'b', assignee: 'core' });
    assert.deepEqual([r.task.id, r.task.state], ['T2', 'ready']);
    assert.deepEqual(b.sent.at(-1), { to: ['core'], ref: 'T2', action: 'add' });
    await rejects(b.as('core').add({ title: 'c' }), 'forbidden');
    await rejects(b.as('stranger').add({ title: 'c' }), 'forbidden');
    await rejects(b.as('pm').add({ title: 'c', assignee: 'ghost' }), 'invalid');
});

both('assign: from new, ready, doing, changes and held the task goes to ready; both assignees are told', async (setup) => {
    for (const from of ['new', 'ready', 'doing', 'changes', 'held']) {
        const b = await setup();
        if (from === 'new') await b.as('pm').add({ id: 'T1', title: 't', reviewer: 'rv' });
        else await taskIn(b, from);
        const r = await b.as('pm').assign({ id: 'T1', assignee: 'app' });
        assert.deepEqual([r.task.state, r.task.assignee], ['ready', 'app'], from);
        assert.deepEqual(b.sent.at(-1).to, from === 'new' ? ['app'] : ['app', 'core'], from);
    }
});

both('assign: a task in review takes no new assignee, a finished one nothing', async (setup) => {
    const b = await setup();
    await taskIn(b, 'review');
    await rejects(b.as('pm').assign({ id: 'T1', assignee: 'app' }), 'invalid-transition');
    await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'));
    await rejects(b.as('pm').assign({ id: 'T1', reviewer: 'app' }), 'invalid-transition');
    await rejects(b.as('core').assign({ id: 'T1', reviewer: 'app' }), 'forbidden');
});

both('assign: in review, a new reviewer keeps the state; both reviewers are told', async (setup) => {
    const b = await setup();
    await taskIn(b, 'review');
    const r = await b.as('pm').assign({ id: 'T1', reviewer: 'app' });
    assert.deepEqual([r.task.state, r.task.reviewer], ['review', 'app']);
    assert.deepEqual(b.sent.at(-1).to, ['app', 'rv']);
    await b.as('app').verdict(judge('T1#1', H('1'), 'approve'));
});

both('assign: a held task without an assignee goes back to review, and its judge is told', async (setup) => {
    const b = await setup();
    await taskIn(b, 'held');
    const r = await b.as('pm').assign({ id: 'T1' });
    assert.equal(r.task.state, 'review');
    assert.deepEqual(b.sent.at(-1), { to: ['rv'], ref: 'T1', action: 'assign' });
    await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'));
});

both('take: ready and changes go to doing, by the assignee only', async (setup) => {
    const b = await setup();
    await taskIn(b, 'ready');
    await rejects(b.as('app').take({ id: 'T1' }), 'forbidden');
    assert.equal((await b.as('core').take({ id: 'T1' })).task.state, 'doing');
    await rejects(b.as('core').take({ id: 'T1' }), 'invalid-transition');
    const c = await setup();
    await taskIn(c, 'changes');
    assert.equal((await c.as('core').take({ id: 'T1' })).task.state, 'doing', 'no pm step after changes');
});

both('land: doing goes to review with the review request row; the reviewer is told, not pm (R70 L2)', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    b.ranges.set(`${BASE}..${H('2')}`, { ancestor: true, commits: [H('1'), H('2')] });
    const r = await b.as('core').land(land('T1', H('2'), { deployed: H('9') }));
    assert.equal(r.task.state, 'review');
    assert.deepEqual([r.landing.id, r.landing.base_commit, r.landing.commits, r.landing.repo], ['T1#1', BASE, [H('1'), H('2')], '/repo']);
    assert.deepEqual(b.sent.at(-1), { to: ['rv'], ref: 'T1#1', action: 'land' });
    await rejects(b.as('app').land(land('T1', H('2'))), 'forbidden');
});

both('land again in review: the open landing is superseded, fixes move to the new one, the judge is told again', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    const r = await b.as('core').land(land('T1', H('3')));
    assert.deepEqual([r.task.state, r.landing.id], ['review', 'T1#3']);
    assert.equal((await b.store.get('landing', 'T1#2')).superseded_by, 'T1#3');
    assert.equal((await b.store.get('finding', 'R1 M1')).fixed_in, 'T1#3');
    assert.deepEqual(b.sent.at(-1), { to: ['rv'], ref: 'T1#3', action: 'land' });
    await rejects(b.as('rv').verdict(judge('T1#2', H('2'), 'approve')), 'stale-landing');
});

both('verdict: approve → done, changes → changes, hold → held; pm and the assignee are told', async (setup) => {
    for (const [verdict, state] of [['approve', 'done'], ['changes', 'changes'], ['hold', 'held']]) {
        const b = await setup();
        await taskIn(b, 'review');
        const r = await b.as('rv').verdict(judge('T1#1', H('1'), verdict));
        assert.equal(r.task.state, state, verdict);
        assert.deepEqual(b.sent.at(-1), { to: ['core', 'pm'], ref: 'R1', action: 'verdict' }, verdict);
    }
});

both('verdict: only the task\'s judge, never the assignee, on the commit of the open landing', async (setup) => {
    const b = await setup();
    await taskIn(b, 'review');
    await rejects(b.as('app').verdict(judge('T1#1', H('1'), 'approve')), 'forbidden');
    await rejects(b.as('pm').verdict(judge('T1#1', H('1'), 'approve')), 'forbidden', 'a reviewer is set');
    await rejects(b.as('rv').verdict(judge('T1#1', H('2'), 'approve')), 'stale-landing');
    await rejects(b.as('rv').verdict(judge('T1#1', H('1'), 'maybe')), 'invalid');
    const c = await setup();
    await taskIn(c, 'review', { reviewer: null });
    await c.as('pm').verdict(judge('T1#1', H('1'), 'approve'));
});

both('cancel: every unfinished state can be cancelled by pm; the assignee (and in review the judge) is told', async (setup) => {
    for (const from of ['ready', 'doing', 'review', 'changes', 'held']) {
        const b = await setup();
        await taskIn(b, from);
        await rejects(b.as('core').cancel({ id: 'T1', findings: 'backlog' }), 'forbidden');
        const r = await b.as('pm').cancel({ id: 'T1', findings: 'backlog' });
        assert.equal(r.task.state, 'cancelled', from);
        assert.deepEqual(b.sent.at(-1).to, from === 'review' ? ['core', 'rv'] : ['core'], from);
        await rejects(b.as('pm').cancel({ id: 'T1' }), 'invalid-transition');
    }
});

both('cancel: the task\'s own unsettled findings must be settled with it; its unapproved fix of another\'s finding reopens', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await rejects(b.as('pm').cancel({ id: 'T1' }), 'invalid');
    const r = await b.as('pm').cancel({ id: 'T1', findings: 'rejected' });
    assert.deepEqual(r.findings, ['R1 M1']);
    assert.equal((await b.store.get('finding', 'R1 M1')).state, 'rejected');

    const c = await setup();
    await taskIn(c, 'changes');
    await c.as('pm').add({ id: 'T1a', parent: 'T1', title: 'fix', assignee: 'app', reviewer: 'rv', base: BASE });
    await c.as('app').take({ id: 'T1a' });
    await c.as('app').land(land('T1a', H('4'), { closes: ['R1 M1'] }));
    await c.as('pm').cancel({ id: 'T1a' });
    assert.deepEqual([(await c.store.get('finding', 'R1 M1')).state, (await c.store.get('finding', 'R1 M1')).fixed_in], ['open', null]);
    assert.equal((await c.as('rv').verdict(judge('T1a#1', H('4'), 'approve')).catch((e) => e)).code, 'invalid-transition', 'a cancelled task\'s landing is not judged');
});

both('a worker is never the judge of its own task', async (setup) => {
    const b = await setup();
    await rejects(b.as('pm').add({ title: 't', assignee: 'core', reviewer: 'core' }), 'invalid');
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv' });
    await rejects(b.as('pm').assign({ id: 'T1', reviewer: 'core' }), 'invalid');
    await rejects(b.as('pm').assign({ id: 'T1', assignee: 'rv' }), 'invalid');
    await b.as('pm').add({ id: 'T2', title: 'pm work', assignee: 'pm', base: BASE });
    await b.as('pm').take({ id: 'T2' });
    await rejects(b.as('pm').land(land('T2', H('1'))), 'invalid', 'pm with no reviewer would judge itself');
    await b.as('pm').assign({ id: 'T2', reviewer: 'rv' });
    await b.as('pm').land(land('T2', H('1')));
});

both('a team that declares no roles: every worker is pm, so landing needs a reviewer', async (setup) => {
    const b = await setup({ roster: [{ name: 'a' }, { name: 'b' }] });
    await b.as('b').add({ id: 'T1', title: 't', assignee: 'a', base: BASE });
    await b.as('a').take({ id: 'T1' });
    await rejects(b.as('a').land(land('T1', H('1'))), 'invalid');
    await b.as('b').assign({ id: 'T1', reviewer: 'b' });
    await b.as('a').land(land('T1', H('1')));
    await b.as('b').verdict(judge('T1#1', H('1'), 'approve'));
});

both('R68 M1 (a): clearing the reviewer of pm\'s own task in review is refused, so pm cannot approve it', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 'pm work', assignee: 'pm', reviewer: 'rv', base: BASE });
    await b.as('pm').take({ id: 'T1' });
    await b.as('pm').land(land('T1', H('1')));
    await rejects(b.as('pm').assign({ id: 'T1', reviewer: '' }), 'invalid');
    await rejects(b.as('pm').assign({ id: 'T1', reviewer: null }), 'invalid');
    await rejects(b.as('pm').verdict(judge('T1#1', H('1'), 'approve')), 'forbidden');
    assert.equal((await b.store.get('task', 'T1')).state, 'review');
    await b.as('pm').assign({ id: 'T1', reviewer: 'app' });
    await b.as('app').verdict(judge('T1#1', H('1'), 'approve'));
});

both('R68 M1 (b): in a team without roles, an assignee who clears the reviewer still cannot judge its own task', async (setup) => {
    const b = await setup({ roster: [{ name: 'aa' }, { name: 'bb' }] });
    await b.as('bb').add({ id: 'T1', title: 't', assignee: 'aa', reviewer: 'bb', base: BASE });
    await b.as('aa').take({ id: 'T1' });
    await b.as('aa').land(land('T1', H('1')));
    await b.as('aa').assign({ id: 'T1', reviewer: null });
    await rejects(b.as('aa').verdict(judge('T1#1', H('1'), 'approve')), 'forbidden');
    assert.equal((await b.as('bb').verdict(judge('T1#1', H('1'), 'approve'))).task.state, 'done');
});

both('R68 M1: a reviewer change that leaves only the assignee to judge is refused, in any state', async (setup) => {
    const b = await setup({ roster: [{ name: 'pm', role: 'orchestrator' }, { name: 'rv', role: 'worker' }] });
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'pm', reviewer: 'rv', base: BASE });
    await rejects(b.as('pm').assign({ id: 'T1', reviewer: null }), 'invalid');
});

both('land on a task with no reviewer tells pm, who judges it', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing', { reviewer: null });
    await b.as('core').land(land('T1', H('1')));
    assert.deepEqual(b.sent.at(-1), { to: ['pm'], ref: 'T1#1', action: 'land' });
});

both('verdict: the report defaults to the landing\'s review report path; rerun stays required (R70 R2)', async (setup) => {
    const b = await setup();
    await taskIn(b, 'review');
    const { report, ...noReport } = judge('T1#1', H('1'), 'changes');
    await rejects(b.as('rv').verdict({ ...noReport, rerun: undefined }), 'invalid');
    const r = await b.as('rv').verdict(noReport);
    assert.equal(r.verdict.report_path, '/r/R.md');
});

both('R68a R1: nobody approves a commit they landed themselves, even after the roles are swapped', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv', base: BASE });
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('1')));
    await b.as('rv').verdict(judge('T1#1', H('1'), 'changes'));
    await b.as('pm').assign({ id: 'T1', assignee: 'app', reviewer: 'core' });
    await b.as('app').take({ id: 'T1' });
    b.ranges.set(`${BASE}..${H('2')}`, { ancestor: true, commits: [H('1'), H('2')] });
    await b.as('app').land(land('T1', H('2')));
    await rejects(b.as('core').verdict(judge('T1#2', H('2'), 'approve')), 'forbidden');
    await b.as('pm').assign({ id: 'T1', reviewer: 'rv' });
    assert.equal((await b.as('rv').verdict(judge('T1#2', H('2'), 'approve'))).task.state, 'done');
});

both('R68 L2: a reviewer can be set from new, ready, doing and changes; the state stays and nobody is told', async (setup) => {
    for (const from of ['new', 'ready', 'doing', 'changes']) {
        const b = await setup();
        if (from === 'new') await b.as('pm').add({ id: 'T1', title: 't' });
        else await taskIn(b, from);
        const sent = b.sent.length;
        const r = await b.as('pm').assign({ id: 'T1', reviewer: 'app' });
        assert.deepEqual([r.task.state, r.task.reviewer], [from, 'app'], from);
        assert.equal(b.sent.length, sent, from);
    }
});

// §2.8 — ids

both('ids: roots number past every T<n> in use, derived tasks take the next letters, a given id is checked', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T59', title: 'r' });
    assert.equal((await b.as('pm').add({ parent: 'T59', title: 'a' })).task.id, 'T59a');
    assert.equal((await b.as('pm').add({ parent: 'T59', title: 'b' })).task.id, 'T59b');
    assert.equal((await b.as('pm').add({ title: 'next' })).task.id, 'T60');
    await rejects(b.as('pm').add({ id: '9x', title: 'x' }), 'invalid');
    await rejects(b.as('pm').add({ id: 'T59', title: 'again' }), 'invalid', 'R68 L1: an id in use is a mistake, not a race');
});

both('derived tasks: from a done parent yes, from a cancelled or derived parent no', async (setup) => {
    const b = await setup();
    await taskIn(b, 'done');
    assert.equal((await b.as('pm').add({ parent: 'T1', title: 'after' })).task.id, 'T1a');
    await rejects(b.as('pm').add({ parent: 'T1a', title: 'grandchild' }), 'invalid');
    await b.as('pm').add({ id: 'T2', title: 'x' });
    await b.as('pm').cancel({ id: 'T2' });
    await rejects(b.as('pm').add({ parent: 'T2', title: 'y' }), 'invalid');
    await rejects(b.as('pm').add({ parent: 'T9', title: 'y' }), 'not-found');
});

both('ids: a family\'s first verdict is the next R<n>, later ones R<n>a, R<n>b; findings are "<verdict> <code>"', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    assert.equal((await b.as('rv').verdict(judge('T1#2', H('2'), 'approve'))).verdict.id, 'R1a');
    await b.as('pm').add({ id: 'T1a', parent: 'T1', title: 'more', assignee: 'core', reviewer: 'rv', base: BASE });
    await b.as('core').take({ id: 'T1a' });
    await b.as('core').land(land('T1a', H('3')));
    const r = await b.as('rv').verdict(judge('T1a#1', H('3'), 'changes', { findings: [must('M1'), { code: 'L1', severity: 'low', summary: 's', repro: 'r' }] }));
    assert.deepEqual([r.verdict.id, r.findings], ['R1b', ['R1b M1', 'R1b L1']]);
    await taskIn(b, 'review', { id: 'T2' });
    assert.equal((await b.as('rv').verdict(judge('T2#1', H('1'), 'approve'))).verdict.id, 'R2');
    await rejects(b.as('rv').verdict(judge('T1a#1', H('3'), 'changes', { findings: [must('M1'), must('M1')] })), 'invalid-transition');
});

test('ids: letters run a … z, aa, ab … az, ba', () => {
    assert.deepEqual(['', 'a', 'y', 'z', 'aa', 'az', 'zz'].map(nextLetters), ['a', 'b', 'z', 'aa', 'ab', 'ba', 'aaa']);
});

// land's inputs

both('land: base defaults to the family\'s last approved commit, then the task\'s base; commits may leave out other work', async (setup) => {
    const b = await setup();
    await taskIn(b, 'done');
    await b.as('pm').add({ id: 'T1a', parent: 'T1', title: 'next', assignee: 'core', reviewer: 'rv' });
    await b.as('core').take({ id: 'T1a' });
    b.ranges.set(`${H('1')}..${H('5')}`, { ancestor: true, commits: [H('4'), H('5')] });
    await rejects(b.as('core').land(land('T1a', H('5'), { commits: [H('5'), H('7')] })), 'invalid');
    await rejects(b.as('core').land(land('T1a', H('5'), { commits: [H('4')] })), 'invalid');
    const r = await b.as('core').land(land('T1a', H('5'), { commits: [H('5')] }));
    assert.deepEqual([r.landing.base_commit, r.landing.commits, r.landing.left_out], [H('1'), [H('5')], [H('4')]]);
    assert.deepEqual((await b.store.get('landing', 'T1a#1')).left_out, [H('4')], 'stored, so the review request shows it (R69 R3)');

    const c = await setup();
    await c.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv' });
    await c.as('core').take({ id: 'T1' });
    await rejects(c.as('core').land(land('T1', H('1'))), 'invalid', 'no base anywhere');
    c.ranges.set(`${H('8')}..${H('1')}`, { ancestor: false, commits: [] });
    await rejects(c.as('core').land(land('T1', H('1'), { base: H('8') })), 'invalid');
    for (const bad of [{ commit: 'abc' }, { focus: [] }, { closes: undefined }, { report: '' }, { check: { cmd: 'x' } }, { repo: undefined }, { review_report: undefined }]) {
        await rejects(c.as('core').land(land('T1', H('1'), { base: BASE, ...bad })), 'invalid');
    }
});

// §3.2 — findings

both('closes: only open findings of the same family', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await taskIn(b, 'changes', { id: 'T2' });
    await b.as('core').take({ id: 'T1' });
    await rejects(b.as('core').land(land('T1', H('2'), { closes: ['R2 M1'] })), 'invalid');
    await rejects(b.as('core').land(land('T1', H('2'), { closes: ['R1 X9'] })), 'invalid');
    const r = await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    assert.deepEqual(r.fixed, ['R1 M1']);
    await b.as('core').land(land('T1', H('3'), {}));
    await rejects(b.as('core').land(land('T1', H('4'), { closes: ['R1 M1'] })), 'invalid', 'already fixed');
});

both('findings: pm settles open or fixed ones and reopens settled ones; the reviewer reopens fixed ones; nothing else', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await rejects(b.as('rv').finding({ id: 'R1 M1', state: 'backlog' }), 'forbidden');
    await rejects(b.as('core').finding({ id: 'R1 M1', state: 'fixed' }), 'invalid-transition');
    for (const to of ['backlog', 'accepted-limit', 'rejected']) {
        assert.equal((await b.as('pm').finding({ id: 'R1 M1', state: to })).finding.state, to);
        assert.equal((await b.as('pm').finding({ id: 'R1 M1', state: 'open' })).finding.state, 'open');
    }
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'open' }), 'forbidden', 'reopening is the reviewer\'s');
    await rejects(b.as('app').finding({ id: 'R1 M1', state: 'open' }), 'forbidden');
    const r = await b.as('rv').finding({ id: 'R1 M1', state: 'open' });
    assert.deepEqual([r.finding.state, r.finding.fixed_in], ['open', null]);
    assert.equal((await b.as('pm').finding({ id: 'R1 M1', state: 'accepted-limit' })).finding.state, 'accepted-limit');
    await b.as('pm').cancel({ id: 'T1', findings: 'backlog' });
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'open' }), 'invalid', 'R68 L3: no unfinished task in the family to fix it in');
    await rejects(b.as('pm').finding({ id: 'R9 M1', state: 'open' }), 'not-found');
});

both('findings: a verdict reopens fixed ones; a family with no unfinished task cannot reopen', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    await rejects(b.as('rv').verdict(judge('T1#2', H('2'), 'changes', { reopen: ['R1 X1'] })), 'invalid');
    const r = await b.as('rv').verdict(judge('T1#2', H('2'), 'changes', { reopen: ['R1 M1'] }));
    assert.deepEqual(r.reopened, ['R1 M1']);
    assert.equal((await b.store.get('finding', 'R1 M1')).state, 'open');

    const c = await setup();
    await taskIn(c, 'changes');
    await c.as('core').take({ id: 'T1' });
    await c.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    await c.as('rv').verdict(judge('T1#2', H('2'), 'approve'));
    await rejects(c.as('rv').finding({ id: 'R1 M1', state: 'open' }), 'invalid');
});

both('approve: refused while the family has an open must finding, from any of its tasks', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await b.as('pm').add({ id: 'T1a', parent: 'T1', title: 'side', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('app').take({ id: 'T1a' });
    await b.as('app').land(land('T1a', H('5')));
    await rejects(b.as('rv').verdict(judge('T1a#1', H('5'), 'approve')), 'invalid');
    await rejects(b.as('rv').verdict(judge('T1a#1', H('5'), 'approve', { findings: [must('M9')] })), 'invalid');
    await b.as('pm').finding({ id: 'R1 M1', state: 'backlog' });
    assert.equal((await b.as('rv').verdict(judge('T1a#1', H('5'), 'approve'))).task.state, 'done');
});

// §4.1 — the task row is the lock

both('each command puts version conditions on exactly the rows of §4.1, and every task write raises the task version', async (setup) => {
    const b = await setup();
    const rec = recording(b.store);
    const as = (who) => b.as(who, { store: rec });
    const last = () => rec.locked.at(-1);
    await as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv', base: BASE });
    assert.deepEqual(last(), []);
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'd', assignee: 'app', reviewer: 'rv', base: BASE });
    assert.deepEqual(last(), ['task T1'], 'add of a derived task: its parent');
    await as('pm').assign({ id: 'T1', reviewer: 'pm' });
    assert.deepEqual(last(), ['task T1']);
    await as('core').take({ id: 'T1' });
    assert.deepEqual(last(), ['task T1']);
    await as('core').land(land('T1', H('1')));
    assert.deepEqual(last(), ['task T1']);
    await as('pm').verdict(judge('T1#1', H('1'), 'changes', { findings: [must('M1')] }));
    assert.deepEqual(last(), ['landing T1#1', 'task T1']);
    await as('app').take({ id: 'T1a' });
    await as('app').land(land('T1a', H('2'), { closes: ['R1 M1'] }));
    assert.deepEqual(last(), ['finding R1 M1', 'task T1', 'task T1a'], 'land: task, root, closes');
    await as('app').land(land('T1a', H('3')));
    assert.deepEqual(last(), ['finding R1 M1', 'landing T1a#1', 'task T1', 'task T1a'], 'resubmit: superseded landing, moved fix');
    await as('rv').verdict(judge('T1a#2', H('3'), 'changes', { reopen: ['R1 M1'] }));
    assert.deepEqual(last(), ['finding R1 M1', 'landing T1a#2', 'task T1', 'task T1a'], 'verdict: task, landing, root, reopened');
    await as('pm').finding({ id: 'R1 M1', state: 'backlog' });
    assert.deepEqual(last(), ['finding R1 M1', 'task T1'], 'finding of the root: finding, its task (= root)');
    await as('pm').cancel({ id: 'T1a' });
    assert.deepEqual(last(), ['task T1', 'task T1a'], 'cancel of a derived task: task, root');
    await as('pm').note({ id: 'T1', body: 'n' });
    assert.deepEqual(last(), [], 'note: nothing');
    await as('pm').announce({ body: 'a' });
    assert.deepEqual(last(), [], 'announce: nothing');
    assert.ok((await b.store.get('task', 'T1')).version > 5);
});

both('a resubmit between the reviewer\'s read and write: the approve does not pass on the superseded landing', async (setup) => {
    const b = await setup();
    await taskIn(b, 'review');
    const racing = interleave(b.store, () => b.as('core').land(land('T1', H('2'))));
    await rejects(b.as('rv', { store: racing }).verdict(judge('T1#1', H('1'), 'approve')), 'stale-landing');
    assert.equal(racing.conflicts, 1);
    assert.deepEqual(await b.store.list('verdict', {}), []);
    assert.equal((await b.store.get('task', 'T1')).state, 'review');
});

both('a must opened in the family between the read and the write of an approve stops the approve', async (setup) => {
    const b = await setup();
    await taskIn(b, 'done');
    await b.as('pm').add({ id: 'T1a', parent: 'T1', title: 'a', assignee: 'core', reviewer: 'rv', base: BASE });
    await b.as('pm').add({ id: 'T1b', parent: 'T1', title: 'b', assignee: 'app', reviewer: 'pm', base: BASE });
    for (const [who, id, c] of [['core', 'T1a', '2'], ['app', 'T1b', '3']]) {
        await b.as(who).take({ id });
        await b.as(who).land(land(id, H(c)));
    }
    const racing = interleave(b.store, () => b.as('pm').verdict(judge('T1b#1', H('3'), 'changes', { findings: [must('M1')] })));
    await rejects(b.as('rv', { store: racing }).verdict(judge('T1a#1', H('2'), 'approve')), 'invalid');
    assert.equal(racing.conflicts, 1, 'the root task lock caught it');
});

both('a write that keeps losing the race ends as a conflict after 3 attempts; one that wins on retry succeeds', async (setup) => {
    const b = await setup();
    await taskIn(b, 'ready');
    let n = 0;
    const always = interleave(b.store, () => b.as('pm').assign({ id: 'T1', reviewer: ['app', 'rv'][n++ % 2] }), 3);
    await rejects(b.as('core', { store: always }).take({ id: 'T1' }), 'conflict');
    assert.equal(always.conflicts, 3);
    const once = interleave(b.store, () => b.as('pm').note({ id: 'T1', body: 'x' }));
    assert.equal((await b.as('core', { store: once }).take({ id: 'T1' })).task.state, 'doing');
    assert.equal(once.conflicts, 0, 'a note locks nothing');
});

// notices and events

both('a failed notice or event is a warning; the change stays', async (setup) => {
    const b = await setup();
    const r = await b.as('pm', { notify: async () => { throw new Error('pane gone'); } }).add({ id: 'T1', title: 't', assignee: 'core' });
    assert.equal(r.ok, true);
    assert.match(r.warning, /pane gone/);
    assert.equal((await b.store.get('task', 'T1')).state, 'ready');
});

both('notes reach their `to`, announcements every other worker; events carry the log seq; nobody is told of their own act', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 't' });
    await b.as('core').note({ id: 'T1', body: 'found x', to: ['pm', 'core'] });
    assert.deepEqual(b.sent.at(-1), { to: ['pm'], ref: 'T1', action: 'note' });
    await rejects(b.as('core').note({ body: 'x', to: ['ghost'] }), 'invalid');
    await b.as('pm').announce({ body: 'rule' });
    assert.deepEqual(b.sent.at(-1).to, ['app', 'core', 'rv']);
    await rejects(b.as('core').announce({ body: 'x' }), 'forbidden');
    const log = await b.store.logSince(0, 100);
    assert.deepEqual(b.events.map((e) => e.log_seq), log.map((e) => e.seq));
    assert.deepEqual(b.events[0], { worker: 'pm', action: 'add', kind: 'task', ref: 'T1', log_seq: 1, state_to: 'new' });
});
