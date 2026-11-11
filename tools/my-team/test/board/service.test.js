/**
 * The board's write commands (T63c) on the memory store: every row of the transition tables
 * (rfc/board-design.md §3.1, §3.2), the id rules (§2.8), the lock table (§4.1) and the notices (§6.2).
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { createBoard } from '../../src/board/core/service.js';
import { nextLetters } from '../../src/board/core/rules.js';
import { createMemoryStore } from '../../src/board/store/memory/index.js';

const ROSTER = [
    { name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' },
    { name: 'app', role: 'worker' }, { name: 'rv', role: 'worker' },
];
const H = (c) => c.repeat(40);
const BASE = H('0');

function setup({ roster = ROSTER } = {}) {
    const store = createMemoryStore();
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

test('add: a task without an assignee is new, with one ready and the assignee is told; only pm adds', async () => {
    const b = setup();
    assert.equal((await b.as('pm').add({ title: 'a' })).task.state, 'new');
    const r = await b.as('pm').add({ title: 'b', assignee: 'core' });
    assert.deepEqual([r.task.id, r.task.state], ['T2', 'ready']);
    assert.deepEqual(b.sent.at(-1), { to: ['core'], ref: 'T2', action: 'add' });
    await rejects(b.as('core').add({ title: 'c' }), 'forbidden');
    await rejects(b.as('stranger').add({ title: 'c' }), 'forbidden');
    await rejects(b.as('pm').add({ title: 'c', assignee: 'ghost' }), 'invalid');
});

test('assign: from new, ready, doing, changes and held the task goes to ready; both assignees are told', async () => {
    for (const from of ['new', 'ready', 'doing', 'changes', 'held']) {
        const b = setup();
        if (from === 'new') await b.as('pm').add({ id: 'T1', title: 't', reviewer: 'rv' });
        else await taskIn(b, from);
        const r = await b.as('pm').assign({ id: 'T1', assignee: 'app' });
        assert.deepEqual([r.task.state, r.task.assignee], ['ready', 'app'], from);
        assert.deepEqual(b.sent.at(-1).to, from === 'new' ? ['app'] : ['app', 'core'], from);
    }
});

test('assign: a task in review takes no new assignee, a finished one nothing', async () => {
    const b = setup();
    await taskIn(b, 'review');
    await rejects(b.as('pm').assign({ id: 'T1', assignee: 'app' }), 'invalid-transition');
    await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'));
    await rejects(b.as('pm').assign({ id: 'T1', reviewer: 'app' }), 'invalid-transition');
    await rejects(b.as('core').assign({ id: 'T1', reviewer: 'app' }), 'forbidden');
});

test('assign: in review, a new reviewer keeps the state; both reviewers are told', async () => {
    const b = setup();
    await taskIn(b, 'review');
    const r = await b.as('pm').assign({ id: 'T1', reviewer: 'app' });
    assert.deepEqual([r.task.state, r.task.reviewer], ['review', 'app']);
    assert.deepEqual(b.sent.at(-1).to, ['app', 'rv']);
    await b.as('app').verdict(judge('T1#1', H('1'), 'approve'));
});

test('assign: a held task without an assignee goes back to review, and its judge is told', async () => {
    const b = setup();
    await taskIn(b, 'held');
    const r = await b.as('pm').assign({ id: 'T1' });
    assert.equal(r.task.state, 'review');
    assert.deepEqual(b.sent.at(-1), { to: ['rv'], ref: 'T1', action: 'assign' });
    await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'));
});

test('take: ready and changes go to doing, by the assignee only', async () => {
    const b = setup();
    await taskIn(b, 'ready');
    await rejects(b.as('app').take({ id: 'T1' }), 'forbidden');
    assert.equal((await b.as('core').take({ id: 'T1' })).task.state, 'doing');
    await rejects(b.as('core').take({ id: 'T1' }), 'invalid-transition');
    const c = setup();
    await taskIn(c, 'changes');
    assert.equal((await c.as('core').take({ id: 'T1' })).task.state, 'doing', 'no pm step after changes');
});

test('land: doing goes to review with the review request row; reviewer and pm are told', async () => {
    const b = setup();
    await taskIn(b, 'doing');
    b.ranges.set(`${BASE}..${H('2')}`, { ancestor: true, commits: [H('1'), H('2')] });
    const r = await b.as('core').land(land('T1', H('2'), { deployed: H('9') }));
    assert.equal(r.task.state, 'review');
    assert.deepEqual([r.landing.id, r.landing.base_commit, r.landing.commits, r.landing.repo], ['T1#1', BASE, [H('1'), H('2')], '/repo']);
    assert.deepEqual(b.sent.at(-1), { to: ['pm', 'rv'], ref: 'T1#1', action: 'land' });
    await rejects(b.as('app').land(land('T1', H('2'))), 'forbidden');
});

test('land again in review: the open landing is superseded, fixes move to the new one, the judge is told again', async () => {
    const b = setup();
    await taskIn(b, 'changes');
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    const r = await b.as('core').land(land('T1', H('3')));
    assert.deepEqual([r.task.state, r.landing.id], ['review', 'T1#3']);
    assert.equal((await b.store.get('landing', 'T1#2')).superseded_by, 'T1#3');
    assert.equal((await b.store.get('finding', 'R1 M1')).fixed_in, 'T1#3');
    assert.deepEqual(b.sent.at(-1), { to: ['pm', 'rv'], ref: 'T1#3', action: 'land' });
    await rejects(b.as('rv').verdict(judge('T1#2', H('2'), 'approve')), 'stale-landing');
});

test('verdict: approve → done, changes → changes, hold → held; pm and the assignee are told', async () => {
    for (const [verdict, state] of [['approve', 'done'], ['changes', 'changes'], ['hold', 'held']]) {
        const b = setup();
        await taskIn(b, 'review');
        const r = await b.as('rv').verdict(judge('T1#1', H('1'), verdict));
        assert.equal(r.task.state, state, verdict);
        assert.deepEqual(b.sent.at(-1), { to: ['core', 'pm'], ref: 'R1', action: 'verdict' }, verdict);
    }
});

test('verdict: only the task\'s judge, never the assignee, on the commit of the open landing', async () => {
    const b = setup();
    await taskIn(b, 'review');
    await rejects(b.as('app').verdict(judge('T1#1', H('1'), 'approve')), 'forbidden');
    await rejects(b.as('pm').verdict(judge('T1#1', H('1'), 'approve')), 'forbidden', 'a reviewer is set');
    await rejects(b.as('rv').verdict(judge('T1#1', H('2'), 'approve')), 'stale-landing');
    await rejects(b.as('rv').verdict(judge('T1#1', H('1'), 'maybe')), 'invalid');
    const c = setup();
    await taskIn(c, 'review', { reviewer: null });
    await c.as('pm').verdict(judge('T1#1', H('1'), 'approve'));
});

test('cancel: every unfinished state can be cancelled by pm; the assignee (and in review the judge) is told', async () => {
    for (const from of ['ready', 'doing', 'review', 'changes', 'held']) {
        const b = setup();
        await taskIn(b, from);
        await rejects(b.as('core').cancel({ id: 'T1', findings: 'backlog' }), 'forbidden');
        const r = await b.as('pm').cancel({ id: 'T1', findings: 'backlog' });
        assert.equal(r.task.state, 'cancelled', from);
        assert.deepEqual(b.sent.at(-1).to, from === 'review' ? ['core', 'rv'] : ['core'], from);
        await rejects(b.as('pm').cancel({ id: 'T1' }), 'invalid-transition');
    }
});

test('cancel: the task\'s own unsettled findings must be settled with it; its unapproved fix of another\'s finding reopens', async () => {
    const b = setup();
    await taskIn(b, 'changes');
    await rejects(b.as('pm').cancel({ id: 'T1' }), 'invalid');
    const r = await b.as('pm').cancel({ id: 'T1', findings: 'rejected' });
    assert.deepEqual(r.findings, ['R1 M1']);
    assert.equal((await b.store.get('finding', 'R1 M1')).state, 'rejected');

    const c = setup();
    await taskIn(c, 'changes');
    await c.as('pm').add({ id: 'T1a', parent: 'T1', title: 'fix', assignee: 'app', reviewer: 'rv', base: BASE });
    await c.as('app').take({ id: 'T1a' });
    await c.as('app').land(land('T1a', H('4'), { closes: ['R1 M1'] }));
    await c.as('pm').cancel({ id: 'T1a' });
    assert.deepEqual([(await c.store.get('finding', 'R1 M1')).state, (await c.store.get('finding', 'R1 M1')).fixed_in], ['open', null]);
    assert.equal((await c.as('rv').verdict(judge('T1a#1', H('4'), 'approve')).catch((e) => e)).code, 'invalid-transition', 'a cancelled task\'s landing is not judged');
});

test('a worker is never the judge of its own task', async () => {
    const b = setup();
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

test('a team that declares no roles: every worker is pm, so landing needs a reviewer', async () => {
    const b = setup({ roster: [{ name: 'a' }, { name: 'b' }] });
    await b.as('b').add({ id: 'T1', title: 't', assignee: 'a', base: BASE });
    await b.as('a').take({ id: 'T1' });
    await rejects(b.as('a').land(land('T1', H('1'))), 'invalid');
    await b.as('b').assign({ id: 'T1', reviewer: 'b' });
    await b.as('a').land(land('T1', H('1')));
    await b.as('b').verdict(judge('T1#1', H('1'), 'approve'));
});

// §2.8 — ids

test('ids: roots number past every T<n> in use, derived tasks take the next letters, a given id is checked', async () => {
    const b = setup();
    await b.as('pm').add({ id: 'T59', title: 'r' });
    assert.equal((await b.as('pm').add({ parent: 'T59', title: 'a' })).task.id, 'T59a');
    assert.equal((await b.as('pm').add({ parent: 'T59', title: 'b' })).task.id, 'T59b');
    assert.equal((await b.as('pm').add({ title: 'next' })).task.id, 'T60');
    await rejects(b.as('pm').add({ id: '9x', title: 'x' }), 'invalid');
    await rejects(b.as('pm').add({ id: 'T59', title: 'again' }), 'conflict');
});

test('derived tasks: from a done parent yes, from a cancelled or derived parent no', async () => {
    const b = setup();
    await taskIn(b, 'done');
    assert.equal((await b.as('pm').add({ parent: 'T1', title: 'after' })).task.id, 'T1a');
    await rejects(b.as('pm').add({ parent: 'T1a', title: 'grandchild' }), 'invalid');
    await b.as('pm').add({ id: 'T2', title: 'x' });
    await b.as('pm').cancel({ id: 'T2' });
    await rejects(b.as('pm').add({ parent: 'T2', title: 'y' }), 'invalid');
    await rejects(b.as('pm').add({ parent: 'T9', title: 'y' }), 'not-found');
});

test('ids: a family\'s first verdict is the next R<n>, later ones R<n>a, R<n>b; findings are "<verdict> <code>"', async () => {
    const b = setup();
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

test('land: base defaults to the family\'s last approved commit, then the task\'s base; commits may leave out other work', async () => {
    const b = setup();
    await taskIn(b, 'done');
    await b.as('pm').add({ id: 'T1a', parent: 'T1', title: 'next', assignee: 'core', reviewer: 'rv' });
    await b.as('core').take({ id: 'T1a' });
    b.ranges.set(`${H('1')}..${H('5')}`, { ancestor: true, commits: [H('4'), H('5')] });
    await rejects(b.as('core').land(land('T1a', H('5'), { commits: [H('5'), H('7')] })), 'invalid');
    await rejects(b.as('core').land(land('T1a', H('5'), { commits: [H('4')] })), 'invalid');
    const r = await b.as('core').land(land('T1a', H('5'), { commits: [H('5')] }));
    assert.deepEqual([r.landing.base_commit, r.landing.commits, r.outside_commits], [H('1'), [H('5')], [H('4')]]);

    const c = setup();
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

test('closes: only open findings of the same family', async () => {
    const b = setup();
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

test('findings: pm settles open or fixed ones and reopens settled ones; the reviewer reopens fixed ones; nothing else', async () => {
    const b = setup();
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
    await rejects(b.as('pm').finding({ id: 'R9 M1', state: 'open' }), 'not-found');
});

test('findings: a verdict reopens fixed ones; a family with no unfinished task cannot reopen', async () => {
    const b = setup();
    await taskIn(b, 'changes');
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    await rejects(b.as('rv').verdict(judge('T1#2', H('2'), 'changes', { reopen: ['R1 X1'] })), 'invalid');
    const r = await b.as('rv').verdict(judge('T1#2', H('2'), 'changes', { reopen: ['R1 M1'] }));
    assert.deepEqual(r.reopened, ['R1 M1']);
    assert.equal((await b.store.get('finding', 'R1 M1')).state, 'open');

    const c = setup();
    await taskIn(c, 'changes');
    await c.as('core').take({ id: 'T1' });
    await c.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    await c.as('rv').verdict(judge('T1#2', H('2'), 'approve'));
    await rejects(c.as('rv').finding({ id: 'R1 M1', state: 'open' }), 'invalid');
});

test('approve: refused while the family has an open must finding, from any of its tasks', async () => {
    const b = setup();
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

test('each command puts version conditions on exactly the rows of §4.1, and every task write raises the task version', async () => {
    const b = setup();
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

test('a resubmit between the reviewer\'s read and write: the approve does not pass on the superseded landing', async () => {
    const b = setup();
    await taskIn(b, 'review');
    const racing = interleave(b.store, () => b.as('core').land(land('T1', H('2'))));
    await rejects(b.as('rv', { store: racing }).verdict(judge('T1#1', H('1'), 'approve')), 'stale-landing');
    assert.equal(racing.conflicts, 1);
    assert.deepEqual(await b.store.list('verdict', {}), []);
    assert.equal((await b.store.get('task', 'T1')).state, 'review');
});

test('a must opened in the family between the read and the write of an approve stops the approve', async () => {
    const b = setup();
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

test('a write that keeps losing the race ends as a conflict after 3 attempts; one that wins on retry succeeds', async () => {
    const b = setup();
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

test('a failed notice or event is a warning; the change stays', async () => {
    const b = setup();
    const r = await b.as('pm', { notify: async () => { throw new Error('pane gone'); } }).add({ id: 'T1', title: 't', assignee: 'core' });
    assert.equal(r.ok, true);
    assert.match(r.warning, /pane gone/);
    assert.equal((await b.store.get('task', 'T1')).state, 'ready');
});

test('notes reach their `to`, announcements every other worker; events carry the log seq; nobody is told of their own act', async () => {
    const b = setup();
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
