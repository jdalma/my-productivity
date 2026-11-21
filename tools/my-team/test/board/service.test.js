/**
 * The board's write commands (T63c) on every store (memory and, where node:sqlite runs, SQLite): every row of
 * the transition tables and the id rules (docs/board.md, States), the task-row lock (core/service.js) and the
 * notices.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { createBoard } from '../../src/board/core/service.js';
import { approvedCommits } from '../../src/board/core/queries.js';
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

// tasks

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

// the user's decision (T115)

const option = (label) => ({ label, detail: `${label} in full`, pros: [`${label} is quick`], cons: [`${label} is narrow`, 'and late'] });
const ask = (id = 'T1', question = 'Which layout?', extra = {}) => ({
    id, question, context: 'The detail view is stuck on its layout; see docs/a.md:12.', options: [option('A'), option('B')],
    recommendation: { option: 'A', reason: 'fits the narrow window' }, impact: 'The detail view waits.', refs: ['docs/a.md'], ...extra,
});
const chose = (chosen = 'A', answer = 'Layout A', id = 'T1') => ({ id, chosen, answer });

both('wait: from every unfinished state, by pm or the assignee; the question and the state it left are kept', async (setup) => {
    for (const from of ['new', 'ready', 'doing', 'changes', 'held', 'review']) {
        const b = await setup();
        if (from === 'new') await b.as('pm').add({ id: 'T1', title: 't' });
        else await taskIn(b, from);
        await rejects(b.as('app').wait(ask()), 'forbidden');
        await rejects(b.as('rv').wait(ask()), 'forbidden');
        const by = from === 'new' ? 'pm' : 'core';
        const r = await b.as(by).wait(ask());
        assert.equal(r.task.state, 'waiting', from);
        const { id: _id, ...brief } = ask();
        assert.deepEqual({ ...r.task.waiting, asked_at: 'x' }, { ...brief, asked_by: by, asked_at: 'x', resume_state: from }, from);
        assert.deepEqual(await b.store.get('task', 'T1').then((t) => [t.state, t.waiting]), ['waiting', r.task.waiting], from);
        await rejects(b.as('pm').wait(ask()), 'invalid-transition');
    }
});

both('wait: a finished task cannot wait, and a question is required', async (setup) => {
    for (const from of ['done', 'cancelled']) {
        const b = await setup();
        await taskIn(b, 'review');
        if (from === 'done') await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'));
        else await b.as('pm').cancel({ id: 'T1' });
        await rejects(b.as('pm').wait(ask()), 'invalid-transition');
    }
    const b = await setup();
    await taskIn(b, 'doing');
    await rejects(b.as('pm').wait(ask('T9')), 'not-found');
});

both('wait: a brief nobody could decide from is refused; impact, refs and the recommendation may be left out', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    const { pros, ...noPros } = option('B');
    for (const bad of [
        { question: '  ' }, { question: undefined }, { context: undefined }, { context: '' },
        { options: undefined }, { options: [option('A')] }, { options: [option('A'), option('A')] },
        { options: [option('A'), noPros] }, { options: [option('A'), { ...option('B'), cons: [] }] },
        { options: [option('A'), { ...option('B'), pros: 'quick' }] }, { options: [option('A'), { ...option('B'), cons: [''] }] },
        { options: [option('A'), { ...option('B'), label: '' }] }, { options: [option('A'), option('기타')] },
        { recommendation: { option: 'C', reason: 'r' } }, { recommendation: { option: 'A' } },
        { refs: 'docs/a.md' }, { impact: 3 },
        { impact: undefined }, { impact: '' }, { impact: '  ' }, { recommendation: undefined }, { recommendation: null },
        { recommendation: { option: null } }, { recommendation: { option: null, reason: '' } }, { recommendation: 'A' },
        { options: [option('A'), option(' A ')] }, { options: [option('A'), option(' 기타 ')] },
    ]) {
        await rejects(b.as('core').wait(ask('T1', 'Which layout?', bad)), 'invalid');
    }
    assert.equal((await b.store.get('task', 'T1')).state, 'doing', 'refused briefs change nothing');
    const r = await b.as('core').wait({
        id: 'T1', question: 'q', context: 'c', options: [{ label: ' yes ', pros: ['p'], cons: ['c'] }, { label: 'no', pros: ['p'], cons: ['c'] }],
        recommendation: { option: null, reason: 'both cost the same' }, impact: 'i',
    });
    assert.deepEqual([r.task.waiting.recommendation, r.task.waiting.refs, r.task.waiting.options[0].detail, r.task.waiting.options[0].label],
        [{ option: null, reason: 'both cost the same' }, [], '', 'yes'], 'no recommendation is said so, and labels are kept trimmed');
    await b.as('pm').answer({ id: 'T1', chosen: '  yes', answer: 'y' });
    await b.as('pm').wait(ask('T1', 'q', { recommendation: { option: ' B ', reason: 'r' } }));
    assert.equal((await b.store.get('task', 'T1')).waiting.recommendation.option, 'B');
    const other = await b.as('pm').answer({ id: 'T1', chosen: ' 기타 ', answer: 'neither' });
    assert.equal(other.decision.chosen, '기타', 'chosen is compared and kept without its spaces');
});

both('answer: pm only; the task goes back to the state it waited from, and the decision is kept with its question', async (setup) => {
    for (const from of ['new', 'ready', 'doing', 'changes', 'held', 'review']) {
        const b = await setup();
        if (from === 'new') await b.as('pm').add({ id: 'T1', title: 't' });
        else await taskIn(b, from);
        await b.as('pm').wait(ask());
        await rejects(b.as('core').answer(chose()), 'forbidden');
        await rejects(b.as('pm').answer({ id: 'T1', chosen: 'A' }), 'invalid');
        await rejects(b.as('pm').answer(chose('C')), 'invalid');
        await rejects(b.as('pm').answer({ id: 'T1', answer: 'A' }), 'invalid');
        const r = await b.as('pm').answer(chose());
        assert.deepEqual([r.task.state, r.task.waiting], [from, null], from);
        const { id: _id, ...asked } = ask();
        assert.deepEqual({ ...r.decision, answered_at: 'x', brief: { ...r.decision.brief, asked_at: 'x' } },
            { question: 'Which layout?', chosen: 'A', answer: 'Layout A', answered_by: 'pm', answered_at: 'x', brief: { ...asked, asked_by: 'pm', asked_at: 'x' } });
        assert.deepEqual(await b.store.get('task', 'T1').then((t) => [t.state, t.waiting]), [from, null], from);
        await rejects(b.as('pm').answer(chose()), 'invalid-transition');
    }
    const b = await setup();
    await taskIn(b, 'doing');
    await b.as('pm').wait(ask());
    assert.equal((await b.as('pm').answer(chose('기타', 'Neither: keep the old one'))).decision.chosen, '기타', 'an answer outside the options');
});

both('while waiting: no take, land or verdict; a note and a cancel still go; a review request is judged once answered', async (setup) => {
    const b = await setup();
    await taskIn(b, 'review');
    await b.as('core').wait(ask());
    await rejects(b.as('rv').verdict(judge('T1#1', H('1'), 'approve')), 'invalid-transition');
    await rejects(b.as('core').land(land('T1', H('2'))), 'invalid-transition');
    await rejects(b.as('core').take({ id: 'T1' }), 'invalid-transition');
    assert.equal((await b.as('core').note({ id: 'T1', body: 'blocked on the user' })).ok, true);
    await b.as('pm').answer(chose());
    assert.equal((await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'))).task.state, 'done');

    const c = await setup();
    await taskIn(c, 'review');
    await c.as('pm').wait(ask());
    const r = await c.as('pm').cancel({ id: 'T1', findings: 'backlog' });
    assert.deepEqual([r.task.state, r.task.waiting], ['cancelled', null]);
    assert.deepEqual(c.sent.at(-1).to, ['core', 'rv'], 'a review request waiting is the judge\'s too');
    assert.equal((await c.store.get('task', 'T1')).waiting, null);
});

both('wait and answer notices: the assignee\'s wait tells pm and the reviewer; pm\'s answer tells the assignee and the reviewer', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    await b.as('core').wait(ask());
    assert.deepEqual(b.sent.at(-1), { to: ['pm', 'rv'], ref: 'T1', action: 'wait' });
    await b.as('pm').answer(chose());
    assert.deepEqual(b.sent.at(-1), { to: ['core', 'rv'], ref: 'T1', action: 'answer' });
    await b.as('pm').wait(ask());
    assert.deepEqual(b.sent.at(-1), { to: ['core', 'rv'], ref: 'T1', action: 'wait' });
    assert.deepEqual(b.events.slice(-3).map((e) => [e.action, e.state_from, e.state_to]),
        [['wait', 'doing', 'waiting'], ['answer', 'waiting', 'doing'], ['wait', 'doing', 'waiting']]);
});

both('a waiting task is not in its assignee\'s hands: it counts for no load warning', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core' });
    await b.as('pm').add({ id: 'T2', title: 't', assignee: 'core' });
    await b.as('pm').wait(ask('T2'));
    await b.as('pm').add({ id: 'T3', title: 't', assignee: 'app' });
    await b.as('app').take({ id: 'T3' });
    await b.as('app').wait(ask('T3'));
    const r = await b.as('pm').add({ id: 'T4', title: 't', assignee: 'core' });
    assert.match(r.warning, /^core now has 2 tasks in hand .* while app has none/);
});

// progress (T127)

const step = (item, done = false, id = 'T1') => ({ id, item, note: `item ${item}: what was done, what is left`, done });

both('progress: the assignee, in doing or changes only; nobody is told', async (setup) => {
    for (const from of ['doing', 'changes']) {
        const b = await setup();
        await taskIn(b, from);
        const sent = b.sent.length;
        await rejects(b.as('pm').progress(step(1)), 'forbidden');
        await rejects(b.as('rv').progress(step(1)), 'forbidden');
        const r = await b.as('core').progress(step(1, true));
        assert.deepEqual({ ...r.progress, at: 'x' }, { item: 1, note: 'item 1: what was done, what is left', done: true, by: 'core', at: 'x' }, from);
        assert.equal(b.sent.length, sent, 'no notice');
        assert.deepEqual(b.events.at(-1).action, 'progress');
        const after = await b.store.get('task', 'T1');
        assert.equal(after.state, from, 'the state stays');
        const before = await b.store.get('task', 'T1');
        await b.as('core').progress(step(2));
        const later = await b.store.get('task', 'T1');
        assert.deepEqual([later.updated_at, later.updated_by, later.version], [before.updated_at, before.updated_by, before.version + 1],
            'updated_at stays: the app counts time in the state from it (R47 S1); the version goes up');
    }
    for (const from of ['ready', 'review', 'held', 'done']) {
        const b = await setup();
        await taskIn(b, from === 'done' ? 'review' : from);
        if (from === 'done') await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'));
        await rejects(b.as('core').progress(step(1)), 'invalid-transition');
    }
    const w = await setup();
    await taskIn(w, 'doing');
    await w.as('core').wait(ask());
    await rejects(w.as('core').progress(step(1)), 'invalid-transition', 'waiting');
});

both('progress: an item number from 0, a note and done are required', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    for (const bad of [{ item: -1 }, { item: 1.5 }, { item: '1' }, { item: undefined }, { note: '' }, { note: undefined }, { done: 'yes' }, { done: undefined }]) {
        await rejects(b.as('core').progress({ ...step(1), ...bad }), 'invalid');
    }
    assert.equal((await b.as('core').progress(step(0))).progress.item, 0, 'work outside the items');
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

both('the review report path is the reviewer\'s: land may suggest one; without it the verdict must name it (R71 R2)', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    const { review_report, ...noSuggestion } = land('T1', H('1'));
    const r = await b.as('core').land(noSuggestion);
    assert.equal(r.landing.review_report_path, null);
    const { report, ...noReport } = judge('T1#1', H('1'), 'changes');
    await rejects(b.as('rv').verdict(noReport), 'invalid');
    assert.equal((await b.as('rv').verdict(judge('T1#1', H('1'), 'changes', { report: '/r/R9.md' }))).verdict.report_path, '/r/R9.md');
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

// ids

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
    for (const bad of [{ commit: 'abc' }, { focus: [] }, { closes: 'R1 M1' }, { report: '' }, { check: { cmd: 'x' } }, { repo: undefined }, { review_report: '' }]) {
        await rejects(c.as('core').land(land('T1', H('1'), { base: BASE, ...bad })), 'invalid');
    }
});

// findings

both('closes: an open finding anywhere on the board; not a missing or an already closed one', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await taskIn(b, 'changes', { id: 'T2' });
    await b.as('core').take({ id: 'T1' });
    await rejects(b.as('core').land(land('T1', H('2'), { closes: ['R1 X9'] })), 'invalid');
    // R2 M1 is T2's: a fix made in T1's work closes it all the same (T87)
    const r = await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1', 'R2 M1'] }));
    assert.deepEqual(r.fixed, ['R1 M1', 'R2 M1']);
    assert.deepEqual([(await b.store.get('finding', 'R2 M1')).state, (await b.store.get('finding', 'R2 M1')).fixed_in], ['fixed', 'T1#2']);
    await b.as('core').land(land('T1', H('3'), {}));
    assert.equal((await b.store.get('finding', 'R2 M1')).fixed_in, 'T1#3', 'a resubmit moves the fix outside the family too');
    await rejects(b.as('core').land(land('T1', H('4'), { closes: ['R1 M1'] })), 'invalid', 'already fixed');
    await rejects(b.as('core').land(land('T1', H('4'), { closes: ['R2 M1'] })), 'invalid', 'already fixed outside the family');
});

both('T120 (R15 L1): closing another family\'s finding tells that family\'s assignee and reviewer too', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    await b.as('pm').add({ id: 'T2', title: 'other', assignee: 'app', reviewer: 'pm', base: BASE });
    await b.as('app').take({ id: 'T2' });
    await b.as('app').land(land('T2', H('5')));
    await b.as('pm').verdict(judge('T2#1', H('5'), 'changes', { findings: [must('M1')] }));
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    assert.deepEqual(b.sent.at(-1), { to: ['app', 'pm', 'rv'], ref: 'T1#1', action: 'land' });
    await b.as('rv').verdict(judge('T1#1', H('2'), 'changes'));
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('3')));
    assert.deepEqual(b.sent.at(-1), { to: ['rv'], ref: 'T1#2', action: 'land' }, 'a land that closes nothing outside goes to its judge alone');
});

both('T140 (R44 L3): closing a finding of another family\'s task with no reviewer tells pm, who judges it', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    await b.as('pm').add({ id: 'T2', title: 'other', assignee: 'app', base: BASE });
    await b.as('app').take({ id: 'T2' });
    await b.as('app').land(land('T2', H('5')));
    await b.as('pm').verdict(judge('T2#1', H('5'), 'changes', { findings: [must('M1')] }));
    await b.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    assert.deepEqual(b.sent.at(-1), { to: ['app', 'pm', 'rv'], ref: 'T1#1', action: 'land' });
});

both('closes outside the family: the reviewer of the landing sees and reopens them; changes keeps them pending; cancel reopens them', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await taskIn(b, 'changes', { id: 'T2' });
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2'), { closes: ['R2 M1'] }));
    // reopen outside the family: only a verdict on the landing that fixed it
    await b.as('pm').add({ id: 'T3', title: 'third', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('app').take({ id: 'T3' });
    await b.as('app').land(land('T3', H('5')));
    await rejects(b.as('rv').verdict(judge('T3#1', H('5'), 'changes', { reopen: ['R2 M1'] })), 'invalid');
    const c = await b.as('rv').verdict(judge('T1#2', H('2'), 'changes'));
    assert.deepEqual([(await b.store.get('finding', 'R2 M1')).state, (await b.store.get('finding', 'R2 M1')).fixed_in], ['fixed', 'T1#2'],
        'changes leaves the fix pending, as in the family');
    assert.equal(c.task.state, 'changes');
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('3')));
    const r = await b.as('rv').verdict(judge('T1#3', H('3'), 'changes', { reopen: ['R2 M1'] }));
    assert.deepEqual(r.reopened, ['R2 M1']);
    assert.deepEqual([(await b.store.get('finding', 'R2 M1')).state, (await b.store.get('finding', 'R2 M1')).fixed_in], ['open', null]);

    const d = await setup();
    await taskIn(d, 'changes');
    await taskIn(d, 'changes', { id: 'T2' });
    await d.as('pm').add({ id: 'T3', title: 'other', assignee: 'app', reviewer: 'rv', base: BASE });
    await d.as('app').take({ id: 'T3' });
    await d.as('app').land(land('T3', H('6'), { closes: ['R2 M1'] }));
    await d.as('pm').cancel({ id: 'T3' });
    assert.deepEqual([(await d.store.get('finding', 'R2 M1')).state, (await d.store.get('finding', 'R2 M1')).fixed_in], ['open', null],
        'a cancelled task\'s unapproved fix outside its family reopens');
});

both('approve: a must finding fixed outside the family still holds the family until that fix is approved', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');                       // T1, open must R1 M1
    await b.as('pm').add({ id: 'T2', title: 'other', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('app').take({ id: 'T2' });
    await b.as('app').land(land('T2', H('6'), { closes: ['R1 M1'] }));
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2')));
    await rejects(b.as('rv').verdict(judge('T1#2', H('2'), 'approve')), 'invalid');
    await b.as('rv').verdict(judge('T2#1', H('6'), 'approve'));
    assert.equal((await b.as('rv').verdict(judge('T1#2', H('2'), 'approve'))).task.state, 'done');
});

both('finding fixed: pm records an approved landing\'s fix after the fact; not an unapproved, a missing or a non-pm one', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');                       // R1 M1 open
    await taskIn(b, 'done', { id: 'T2' });            // T2#1 approved
    await b.as('pm').add({ id: 'T3', title: 'other', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('app').take({ id: 'T3' });
    await b.as('app').land(land('T3', H('6')));       // T3#1 not approved
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed' }), 'invalid', 'no landing');
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T9#1' }), 'not-found');
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T3#1' }), 'invalid', 'not approved');
    await rejects(b.as('rv').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' }), 'forbidden');
    const r = await b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' });
    assert.deepEqual([r.finding.state, r.finding.fixed_in], ['fixed', 'T2#1']);
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' }), 'invalid-transition', 'only an open one');
});

/** T1 done with its finding R1 M1 settled as `settled`, and T2 of another family in doing for app. */
async function settledAndCleanup(b, settled = 'backlog') {
    await taskIn(b, 'changes');
    await b.as('pm').finding({ id: 'R1 M1', state: settled });
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(land('T1', H('2')));
    await b.as('rv').verdict(judge('T1#2', H('2'), 'approve'));
    await b.as('pm').add({ id: 'T2', title: 'cleanup', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('app').take({ id: 'T2' });
}
const stateOf = async (b, id) => { const f = await b.store.get('finding', id); return [f.state, f.fixed_in ?? null]; };

both('T198 closes: a backlog finding stays backlog until the task is approved, then is fixed in the approved landing', async (setup) => {
    const b = await setup();
    await settledAndCleanup(b);
    const l = await b.as('app').land(land('T2', H('5'), { closes: ['R1 M1'] }));
    assert.deepEqual(l.fixed, [], 'nothing is fixed at the land');
    assert.deepEqual(await stateOf(b, 'R1 M1'), ['backlog', null]);
    const c = await b.as('rv').verdict(judge('T2#1', H('5'), 'changes'));
    assert.deepEqual([c.fixed, await stateOf(b, 'R1 M1')], [[], ['backlog', null]], 'changes leaves it backlog');
    await b.as('app').take({ id: 'T2' });
    await b.as('app').land(land('T2', H('6'), { closes: ['R1 M1'] }));
    const a = await b.as('rv').verdict(judge('T2#2', H('6'), 'approve'));
    assert.deepEqual(a.fixed, ['R1 M1']);
    assert.deepEqual(await stateOf(b, 'R1 M1'), ['fixed', 'T2#2']);

    for (const [verdict, after] of [['hold', null], [null, 'cancel']]) {
        const d = await setup();
        await settledAndCleanup(d);
        await d.as('app').land(land('T2', H('5'), { closes: ['R1 M1'] }));
        if (verdict) await d.as('rv').verdict(judge('T2#1', H('5'), verdict));
        if (after) await d.as('pm').cancel({ id: 'T2' });
        assert.deepEqual(await stateOf(d, 'R1 M1'), ['backlog', null], `${verdict ?? after} leaves it backlog`);
    }
});

both('T198 closes: only the approved landing\'s own closes count; an earlier landing\'s claim is gone with it', async (setup) => {
    const b = await setup();
    await settledAndCleanup(b);
    await b.as('app').land(land('T2', H('5'), { closes: ['R1 M1'] }));
    await b.as('rv').verdict(judge('T2#1', H('5'), 'changes'));
    await b.as('app').take({ id: 'T2' });
    await b.as('app').land(land('T2', H('6')));
    const a = await b.as('rv').verdict(judge('T2#2', H('6'), 'approve'));
    assert.deepEqual([a.fixed, await stateOf(b, 'R1 M1')], [[], ['backlog', null]], 'the resubmit did not name it');

    // a fix the reviewer reopened and pm then settled as backlog is not fixed by a later landing that names nothing
    const c = await setup();
    await taskIn(c, 'changes');
    await c.as('core').take({ id: 'T1' });
    await c.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    await c.as('rv').verdict(judge('T1#2', H('2'), 'changes', { reopen: ['R1 M1'] }));
    await c.as('pm').finding({ id: 'R1 M1', state: 'backlog' });
    await c.as('core').take({ id: 'T1' });
    await c.as('core').land(land('T1', H('3')));
    const d = await c.as('rv').verdict(judge('T1#3', H('3'), 'approve'));
    assert.deepEqual([d.task.state, d.fixed, await stateOf(c, 'R1 M1')], ['done', [], ['backlog', null]]);
});

both('T198 closes: an approve may keep a backlog finding back with reopen; it stays backlog', async (setup) => {
    const b = await setup();
    await settledAndCleanup(b);
    await b.as('app').land(land('T2', H('5'), { closes: ['R1 M1'] }));
    const a = await b.as('rv').verdict(judge('T2#1', H('5'), 'approve', { reopen: ['R1 M1'] }));
    assert.deepEqual([a.task.state, a.fixed, a.reopened], ['done', [], []], 'nothing was reopened: it never left backlog');
    assert.deepEqual(await stateOf(b, 'R1 M1'), ['backlog', null]);

    // a must finding of the landing's own family too: backlog is settled, so it does not hold the approve
    const f = await setup();
    await taskIn(f, 'changes');
    await f.as('pm').finding({ id: 'R1 M1', state: 'backlog' });
    await f.as('core').take({ id: 'T1' });
    await f.as('core').land(land('T1', H('2'), { closes: ['R1 M1'] }));
    const g = await f.as('rv').verdict(judge('T1#2', H('2'), 'approve', { reopen: ['R1 M1'] }));
    assert.deepEqual([g.task.state, g.fixed, await stateOf(f, 'R1 M1')], ['done', [], ['backlog', null]]);

    const c = await setup();
    await settledAndCleanup(c);
    await c.as('app').land(land('T2', H('5')));
    await rejects(c.as('rv').verdict(judge('T2#1', H('5'), 'approve', { reopen: ['R1 M1'] })), 'invalid', 'a backlog finding no landing of the task named');
});

both('T198 closes: not an accepted-limit or a rejected finding, nor a finding of another team\'s board', async (setup) => {
    for (const settled of ['accepted-limit', 'rejected']) {
        const b = await setup();
        await settledAndCleanup(b, settled);
        await rejects(b.as('app').land(land('T2', H('5'), { closes: ['R1 M1'] })), 'invalid');
        await b.as('app').land(land('T2', H('5')));
        await b.as('rv').verdict(judge('T2#1', H('5'), 'approve'));
        await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' }), 'invalid-transition');
        assert.deepEqual(await stateOf(b, 'R1 M1'), [settled, null]);
    }
    const mine = await setup(), other = await setup();
    await settledAndCleanup(other);
    await taskIn(mine, 'done');
    await mine.as('pm').add({ id: 'T2', title: 'cleanup', assignee: 'app', reviewer: 'rv', base: BASE });
    await mine.as('app').take({ id: 'T2' });
    await rejects(mine.as('app').land(land('T2', H('5'), { closes: ['R1 M1'] })), 'invalid');
    await rejects(mine.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T1#1' }), 'not-found');
    assert.deepEqual(await stateOf(other, 'R1 M1'), ['backlog', null]);
});

both('T198 finding fixed: pm moves a backlog finding to fixed with an approved landing; not an unapproved one, not a non-pm', async (setup) => {
    const b = await setup();
    await settledAndCleanup(b);
    await b.as('app').land(land('T2', H('5')));
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed' }), 'invalid', 'no landing');
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' }), 'invalid', 'not approved');
    await b.as('rv').verdict(judge('T2#1', H('5'), 'approve'));
    await rejects(b.as('rv').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' }), 'forbidden');
    const r = await b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' });
    assert.deepEqual([r.finding.state, r.finding.fixed_in], ['fixed', 'T2#1']);
});

both('T198 closes: an approve that fixes a backlog finding of another family locks that finding\'s task', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');                       // T1 unfinished, so pm can reopen R1 M1
    await b.as('pm').finding({ id: 'R1 M1', state: 'backlog' });
    await b.as('pm').add({ id: 'T2', title: 'cleanup', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('app').take({ id: 'T2' });
    await b.as('app').land(land('T2', H('5'), { closes: ['R1 M1'] }));
    const store = interleave(b.store, () => b.as('pm').finding({ id: 'R1 M1', state: 'open' }));
    const a = await b.as('rv', { store }).verdict(judge('T2#1', H('5'), 'approve'));
    assert.equal(store.conflicts, 1, 'the approve read the finding again');
    assert.deepEqual([a.fixed, await stateOf(b, 'R1 M1')], [[], ['open', null]], 'pm reopened it first: the approve leaves it');
});

both('findings: pm settles open or fixed ones and reopens settled ones; the reviewer reopens fixed ones; nothing else', async (setup) => {
    const b = await setup();
    await taskIn(b, 'changes');
    await rejects(b.as('rv').finding({ id: 'R1 M1', state: 'backlog' }), 'forbidden');
    await rejects(b.as('core').finding({ id: 'R1 M1', state: 'fixed' }), 'forbidden', 'recording a fix is pm\'s');
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

// the task row is the lock

both('a write that changes a finding of another family locks that finding\'s task and root', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T2', title: 'other', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('pm').add({ id: 'T2a', parent: 'T2', title: 'derived', assignee: 'app', reviewer: 'rv', base: BASE });
    await b.as('app').take({ id: 'T2a' });
    await b.as('app').land(land('T2a', H('7')));
    await b.as('rv').verdict(judge('T2a#1', H('7'), 'changes', { findings: [must('M1')] }));   // R1 M1 is T2a's
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv', base: BASE });
    await b.as('core').take({ id: 'T1' });
    const rec = recording(b.store);
    await b.as('core', { store: rec }).land(land('T1', H('1'), { closes: ['R1 M1'] }));
    assert.deepEqual(rec.locked.at(-1), ['finding R1 M1', 'task T1', 'task T2', 'task T2a'], 'land: its task, the finding, its task and root');
    await b.as('rv', { store: rec }).verdict(judge('T1#1', H('1'), 'changes', { reopen: ['R1 M1'] }));
    assert.deepEqual(rec.locked.at(-1), ['finding R1 M1', 'landing T1#1', 'task T1', 'task T2', 'task T2a'], 'verdict reopening it: the same');
});

both('each command puts version conditions on exactly the rows its lock rule names, and every task write raises the task version', async (setup) => {
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

const reviewed = { reviewer: 'rv', base: BASE };
async function inReview(b, id, who) {
    await b.as('pm').add({ id, title: 't', assignee: who, ...reviewed });
    await b.as(who).take({ id });
    await b.as(who).land(land(id, H('1')));
}

both('add: a second task in hand for a worker while another who has had a task holds none is a warning; the task is added', async (setup) => {
    const b = await setup();
    assert.equal((await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core' })).warning, undefined, 'a first task');
    await inReview(b, 'T2', 'app');
    const r = await b.as('pm').add({ id: 'T3', title: 't', assignee: 'core' });
    assert.equal(r.ok, true);
    assert.equal(r.warning, 'core now has 2 tasks in hand (ready, doing or changes) while app has none: split the task or give it to app');
    assert.equal((await b.store.get('task', 'T3')).state, 'ready');
    assert.deepEqual(b.sent.at(-1), { to: ['core'], ref: 'T3', action: 'add' });
});

both('add: when no other worker who has taken a task is free, the warning asks whether the task can run in parallel and names a worker with no task yet; none while the assignee holds one task', async (setup) => {
    const line = (where) => `core now has 2 tasks in hand (ready, doing or changes) and no other worker who has taken a task is free: if this task can run in parallel with the work in hand, ${where}; if not, leave it queued`;
    const add = 'add a worker for it';
    const busy = await setup();
    await busy.as('pm').add({ id: 'T1', title: 't', assignee: 'core' });
    await busy.as('pm').add({ id: 'T2', title: 't', assignee: 'app' });
    assert.equal((await busy.as('pm').add({ id: 'T3', title: 't', assignee: 'core' })).warning, line(`give it to rv (no task yet) if that worker is there to take tasks, or ${add}`), 'app has a task in hand; rv has had none, and pm is the orchestrator');

    const alone = await setup();
    await alone.as('pm').add({ id: 'T1', title: 't', assignee: 'core' });
    assert.equal((await alone.as('pm').add({ id: 'T2', title: 't', assignee: 'core' })).warning, line(`give it to app or rv (no task yet) if that worker is there to take tasks, or ${add}`), 'app and rv never had a task');

    const reviewed = await setup();
    await reviewed.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv' });
    await reviewed.as('pm').add({ id: 'T2', title: 't', assignee: 'app', reviewer: 'rv' });
    assert.equal((await reviewed.as('pm').add({ id: 'T3', title: 't', assignee: 'core' })).warning, line(add), 'rv reviews tasks, so it is not named as free');

    const peers = await setup({ roster: [{ name: 'a' }, { name: 'b' }, { name: 'c' }] });
    await peers.as('a').add({ id: 'T1', title: 't', assignee: 'b' });
    assert.equal((await peers.as('a').add({ id: 'T2', title: 't', assignee: 'b' })).warning, line(add).replace('core', 'b'), 'a team without roles: every worker is pm, so none is named');

    const moved = await setup();
    await moved.as('pm').add({ id: 'T1', title: 't', assignee: 'core' });
    await moved.as('pm').add({ id: 'T2', title: 't', assignee: 'app' });
    await moved.as('pm').add({ id: 'T3', title: 't' });
    assert.equal((await moved.as('pm').assign({ id: 'T3', assignee: 'core' })).warning, line(`give it to rv (no task yet) if that worker is there to take tasks, or ${add}`), 'board-assign gives the same line');

    const waiting = await setup();
    await inReview(waiting, 'T1', 'core');
    await inReview(waiting, 'T2', 'app');
    assert.equal((await waiting.as('pm').add({ id: 'T3', title: 't', assignee: 'core' })).warning, undefined, 'core has one task in hand');
    await waiting.as('pm').add({ id: 'T4', title: 't', assignee: 'core' });
    assert.equal((await waiting.as('pm').add({ id: 'T5', title: 't' })).warning, undefined, 'a task for nobody');
});

both('assign: the warning comes when a task moves to a loaded worker, not when it stays or only its reviewer changes', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core' });
    await b.as('pm').add({ id: 'T2', title: 't', assignee: 'core' });
    await inReview(b, 'T3', 'app');
    await b.as('rv').verdict(judge('T3#1', H('1'), 'approve'));
    await b.as('pm').add({ id: 'T4', title: 't' });
    const r = await b.as('pm').assign({ id: 'T4', assignee: 'core' });
    assert.match(r.warning, /^core now has 3 tasks in hand .* while app has none/);
    assert.equal(r.task.assignee, 'core');
    assert.equal((await b.as('pm').assign({ id: 'T4', assignee: 'core' })).warning, undefined, 'the same assignee again');
    assert.equal((await b.as('pm').assign({ id: 'T4', reviewer: 'rv' })).warning, undefined, 'a reviewer change');
    assert.equal((await b.as('pm').assign({ id: 'T4', assignee: 'app' })).warning, undefined, 'to the idle worker');
});

both('assign: a held task released to the same assignee comes back into their hands, so the warning comes (R26 L1)', async (setup) => {
    const b = await setup();
    await inReview(b, 'T1', 'app');
    await b.as('rv').verdict(judge('T1#1', H('1'), 'approve'));
    await b.as('pm').add({ id: 'T2', title: 't', assignee: 'core' });
    await inReview(b, 'T3', 'core');
    await b.as('rv').verdict(judge('T3#1', H('1'), 'hold'));
    const r = await b.as('pm').assign({ id: 'T3', assignee: 'core' });
    assert.equal(r.task.state, 'ready');
    assert.match(r.warning, /^core now has 2 tasks in hand .* while app has none/);
});

both('a load warning and a failed notice share the warning field', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core' });
    await inReview(b, 'T2', 'app');
    const r = await b.as('pm', { notify: async () => { throw new Error('pane gone'); } }).add({ id: 'T3', title: 't', assignee: 'core' });
    assert.match(r.warning, /^core now has 2 tasks in hand .*; notify: pane gone$/);
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

// ── board-edit and document tasks (T158) ────────────────────────────────────────────────────────

both('land: closes may be left out, and is then none (T159)', async (setup) => {
    const b = await setup();
    await taskIn(b, 'doing');
    const { closes: _, ...noCloses } = land('T1', H('1'));
    const l = await b.as('core').land(noCloses);
    assert.deepEqual([l.landing.closes, l.fixed, l.task.state], [[], [], 'review']);
    await rejects(b.as('core').land({ ...noCloses, closes: 'R1 M1' }), 'invalid');
});

both('edit: pm corrects what a task says; the log says what changed, and nobody else may', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv', base: BASE });
    await b.as('core').take({ id: 'T1' });
    const before = await b.store.get('task', 'T1');
    b.sent.length = 0;
    const r = await b.as('pm').edit({ id: 'T1', title: 'better', ticket: '/t/T1.md', constraints: '없음', base: H('9'), priority: 5 });
    assert.deepEqual(
        [r.task.title, r.task.ticket_path, r.task.constraints, r.task.base_commit, r.task.priority, r.task.state],
        ['better', '/t/T1.md', '없음', H('9'), 5, 'doing'],
    );
    const row = await b.store.get('task', 'T1');
    assert.deepEqual(row, r.task, 'the command answers the row the board keeps');
    assert.equal(row.updated_at, before.updated_at, 'an edit is no move: how long the task is in its state is counted from updated_at');
    const entry = (await b.store.logOf(['T1'])).at(-1);
    assert.deepEqual([entry.action, entry.actor, entry.state_to ?? null], ['edit', 'pm', null]);
    assert.deepEqual(entry.detail.changed, {
        title: { from: 't', to: 'better' }, ticket_path: { from: null, to: '/t/T1.md' }, constraints: { from: null, to: '없음' },
        base_commit: { from: BASE, to: H('9') }, priority: { from: 100, to: 5 },
    });
    assert.deepEqual(b.sent, [{ to: ['core'], ref: 'T1', action: 'edit' }], 'the assignee hears; the reviewer does once the task is in review');

    await rejects(b.as('core').edit({ id: 'T1', title: 'mine' }), 'forbidden');
    await rejects(b.as('pm').edit({ id: 'T1' }), 'invalid');
    await rejects(b.as('pm').edit({ id: 'T1', title: 'better', priority: 5 }), 'invalid');   // nothing changes
    await rejects(b.as('pm').edit({ id: 'T1', title: ' ' }), 'invalid');
    await rejects(b.as('pm').edit({ id: 'T1', base: 'abc' }), 'invalid');
    await rejects(b.as('pm').edit({ id: 'T1', priority: 1.5 }), 'invalid');
    await rejects(b.as('pm').edit({ id: 'T1', assignee: 'app' }), 'invalid');   // board-assign's
    await rejects(b.as('pm').edit({ id: 'T9', title: 'x' }), 'not-found');

    await b.as('core').land(land('T1', H('1'), { base: BASE }));
    b.sent.length = 0;
    await b.as('pm').edit({ id: 'T1', constraints: 'tmux -L only' });
    assert.deepEqual(b.sent, [{ to: ['core', 'rv'], ref: 'T1', action: 'edit' }]);
});

both('edit: a finished task stays as it was', async (setup) => {
    const b = await setup();
    await taskIn(b, 'done');
    await rejects(b.as('pm').edit({ id: 'T1', title: 'late' }), 'invalid-transition');
    await b.as('pm').add({ id: 'T2', title: 't' });
    await b.as('pm').cancel({ id: 'T2' });
    await rejects(b.as('pm').edit({ id: 'T2', title: 'late' }), 'invalid-transition');
});

const report = (id, extra = {}) => ({ id, check: { cmd: 'read the report against the ticket', result: 'every item answered' }, focus: ['one'], closes: [], report: '/r/advice.md', ...extra });

both('a document task lands a report with no commit, is judged, and is done', async (setup) => {
    const b = await setup();
    const added = await b.as('pm').add({ id: 'T1', title: 'advice', assignee: 'core', reviewer: 'rv', deliverable: 'document' });
    assert.equal(added.task.deliverable, 'document');
    await b.as('core').take({ id: 'T1' });
    await rejects(b.as('core').land(land('T1', H('1'), { base: BASE })), 'invalid');   // a commit on a document task
    const l = await b.as('core').land(report('T1'));
    assert.deepEqual(
        [l.landing.id, l.landing.commit, l.landing.base_commit, l.landing.commits, l.landing.left_out, l.landing.repo, l.task.state],
        ['T1#1', '', '', [], [], '', 'review'],
        'the landing keeps its fields as text and lists, empty: what reads a landing reads this one',
    );
    assert.deepEqual(b.sent.at(-1), { to: ['rv'], ref: 'T1#1', action: 'land' });

    await rejects(b.as('core').verdict(judge('T1#1', '', 'approve')), 'forbidden');   // its own work
    await rejects(b.as('rv').verdict(judge('T1#1', H('1'), 'approve')), 'stale-landing');
    await b.as('rv').verdict(judge('T1#1', '', 'changes', { findings: [must('M1')] }));
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(report('T1', { closes: ['R1 M1'] }));
    const { verified_commit: _, ...noCommit } = judge('T1#2', '', 'approve');
    const v = await b.as('rv').verdict(noCommit);
    assert.deepEqual([v.task.state, v.verdict.verified_commit], ['done', ''], 'verified_commit may be left out: there is none');
    assert.deepEqual(await approvedCommits(b.store, ['', '/repo']), new Set(), 'nothing becomes pushable by it');
});

both('a document task: pm cannot land a report only pm would judge', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T2', title: 'pm writes', assignee: 'pm', deliverable: 'document' });
    await b.as('pm').take({ id: 'T2' });
    await rejects(b.as('pm').land(report('T2')), 'invalid');
});

both('a task that needs commits cannot land without one; edit marks a document task until a commit was landed', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 'code', assignee: 'core', reviewer: 'rv', base: BASE });
    await b.as('core').take({ id: 'T1' });
    await rejects(b.as('core').land(report('T1')), 'invalid');
    await rejects(b.as('pm').add({ id: 'T9', title: 'x', deliverable: 'paper' }), 'invalid');

    // registered without the mark (T150, T151): pm marks it, and it lands its report
    const marked = await b.as('pm').edit({ id: 'T1', deliverable: 'document' });
    assert.equal(marked.task.deliverable, 'document');
    assert.deepEqual((await b.store.logOf(['T1'])).at(-1).detail.changed, { deliverable: { from: null, to: 'document' } });
    await b.as('core').land(report('T1'));
    await b.as('rv').verdict(judge('T1#1', '', 'approve'));
    assert.equal((await b.store.get('task', 'T1')).state, 'done');

    // and back, while nothing was landed
    await b.as('pm').add({ id: 'T2', title: 'doc?', assignee: 'core', reviewer: 'rv', base: BASE, deliverable: 'document' });
    assert.equal((await b.as('pm').edit({ id: 'T2', deliverable: 'commits' })).task.deliverable, null);

    // a commit was landed: the task is no document task
    await b.as('core').take({ id: 'T2' });
    await b.as('core').land(land('T2', H('2')));
    await rejects(b.as('pm').edit({ id: 'T2', deliverable: 'document' }), 'invalid');
    await b.as('rv').verdict(judge('T2#1', H('2'), 'changes'));
    await rejects(b.as('pm').edit({ id: 'T2', deliverable: 'document' }), 'invalid');
});

both('a document task\'s report fixes no finding of a task that delivers commits (R8 S1)', async (setup) => {
    const b = await setup();
    await taskIn(b, 'review');
    await b.as('rv').verdict(judge('T1#1', H('1'), 'changes', { findings: [must('M1')] }));
    await b.as('pm').add({ id: 'T2', title: 'advice', assignee: 'app', reviewer: 'rv', deliverable: 'document' });
    await b.as('app').take({ id: 'T2' });
    await rejects(b.as('app').land(report('T2', { closes: ['R1 M1'] })), 'invalid');
    await b.as('app').land(report('T2'));
    await b.as('rv').verdict(judge('T2#1', '', 'approve'));
    await rejects(b.as('pm').finding({ id: 'R1 M1', state: 'fixed', landing: 'T2#1' }), 'invalid');   // nor after the fact
    assert.equal((await b.store.get('finding', 'R1 M1')).state, 'open');

    // a document task's own finding, and another document task's, are a report's to fix
    await b.as('pm').add({ id: 'T3', title: 'plan', assignee: 'core', reviewer: 'rv', deliverable: 'document' });
    await b.as('core').take({ id: 'T3' });
    await b.as('core').land(report('T3'));
    await b.as('rv').verdict(judge('T3#1', '', 'changes', { findings: [must('M1'), must('M2')] }));
    await b.as('pm').add({ id: 'T4', title: 'more advice', assignee: 'app', reviewer: 'rv', deliverable: 'document' });
    await b.as('app').take({ id: 'T4' });
    assert.deepEqual((await b.as('app').land(report('T4', { closes: ['R3 M2'] }))).fixed, ['R3 M2']);
    await b.as('core').take({ id: 'T3' });
    assert.deepEqual((await b.as('core').land(report('T3', { closes: ['R3 M1'] }))).fixed, ['R3 M1']);
});

both('a document task: whoever landed a report of it does not judge it, whoever has it now (R8 S2)', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 'advice', assignee: 'core', reviewer: 'rv', deliverable: 'document' });
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(report('T1'));
    await b.as('rv').verdict(judge('T1#1', '', 'changes'));
    await b.as('pm').assign({ id: 'T1', assignee: 'app', reviewer: 'core' });
    await b.as('app').take({ id: 'T1' });
    await b.as('app').land(report('T1', { report: '/r/advice-2.md' }));
    await rejects(b.as('core').verdict(judge('T1#2', '', 'approve')), 'forbidden');
    await b.as('pm').assign({ id: 'T1', reviewer: 'rv' });
    assert.equal((await b.as('rv').verdict(judge('T1#2', '', 'approve'))).task.state, 'done');
});

both('a document task: its mark does not change while a report waits for its verdict; an approved report is no base of a commit', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 'plan', assignee: 'core', reviewer: 'rv', deliverable: 'document' });
    await b.as('core').take({ id: 'T1' });
    await b.as('core').land(report('T1'));
    await rejects(b.as('pm').edit({ id: 'T1', deliverable: 'commits' }), 'invalid');   // or the report would be approved as commits
    await b.as('pm').edit({ id: 'T1', title: 'the plan' });
    await b.as('rv').verdict(judge('T1#1', '', 'approve'));

    // the work the plan asked for, in its family: its base is the task's, not the report's empty commit
    await b.as('pm').add({ id: 'T1a', parent: 'T1', title: 'build it', assignee: 'core', reviewer: 'rv', base: BASE });
    await b.as('core').take({ id: 'T1a' });
    const l = await b.as('core').land(land('T1a', H('1')));
    assert.deepEqual([l.landing.base_commit, l.landing.commits], [BASE, [H('1')]]);
});

// warnings: advice in `warnings`, the command goes through (E23, E24, E25)

both('add: no reviewer, or pm as reviewer, is a warning; another worker as reviewer is none (E23)', async (setup) => {
    const b = await setup();
    const none = await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core' });
    assert.match(none.warnings[0], /no reviewer: pm judges T1/);
    const pm = await b.as('pm').add({ id: 'T2', title: 't', assignee: 'core', reviewer: 'pm' });
    assert.match(pm.warnings[0], /reviewer pm is the team's pm/);
    assert.equal((await b.store.get('task', 'T2')).reviewer, 'pm');
    assert.equal((await b.as('pm').add({ id: 'T3', title: 't', assignee: 'app', reviewer: 'rv' })).warnings, undefined);
});

both('assign: changing the reviewer to pm or to none is a warning; changing only the assignee is none (E23)', async (setup) => {
    const b = await setup();
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv' });
    assert.match((await b.as('pm').assign({ id: 'T1', reviewer: 'pm' })).warnings[0], /reviewer pm is the team's pm/);
    assert.match((await b.as('pm').assign({ id: 'T1', reviewer: null })).warnings[0], /no reviewer/);
    assert.equal((await b.as('pm').assign({ id: 'T1', reviewer: 'rv' })).warnings, undefined);
    assert.equal((await b.as('pm').assign({ id: 'T1', assignee: 'app' })).warnings, undefined);
});

both('a team with no roles has no independent reviewer to ask for: no reviewer warning (E23)', async (setup) => {
    const b = await setup({ roster: [{ name: 'a' }, { name: 'b' }] });
    assert.equal((await b.as('a').add({ id: 'T1', title: 't', assignee: 'b' })).warnings, undefined);
});

both('ask: a question over 120 characters or a context over 1000 is a warning; the decision is made (E24)', async (setup) => {
    const b = await setup();
    assert.equal((await b.as('core').ask(ask(undefined, 'x'.repeat(120)))).warnings, undefined);
    const r = await b.as('core').ask(ask(undefined, 'x'.repeat(121), { context: 'c'.repeat(1001) }));
    assert.deepEqual(r.warnings.map((w) => w.slice(0, 21)), ['question is 121 chars', 'context is 1001 chars']);
    assert.equal((await b.store.get('decision', r.decision.id)).state, 'open');
});

both('ask and wait: a fourth open decision of one asker is a warning; others\' and answered ones do not count (E24)', async (setup) => {
    const b = await setup();
    for (let i = 0; i < 3; i++) assert.equal((await b.as('core').ask(ask())).warnings, undefined);
    assert.equal((await b.as('app').ask(ask())).warnings, undefined, 'another asker');
    const r = await b.as('core').ask(ask());
    assert.match(r.warnings[0], /core now has 4 open decisions, more than 3/);
    await b.as('pm').add({ id: 'T1', title: 't', assignee: 'core', reviewer: 'rv' });
    assert.match((await b.as('core').wait(ask('T1'))).warnings[0], /core now has 5 open decisions/);
    await b.as('pm').answer({ id: 'D#1', chosen: 'A', answer: 'a' });
    await b.as('pm').add({ id: 'T2', title: 't', assignee: 'core', reviewer: 'rv' });
    assert.match((await b.as('core').wait(ask('T2'))).warnings[0], /core now has 5 open decisions/, 'D#1 answered, T1 still waits');
});
