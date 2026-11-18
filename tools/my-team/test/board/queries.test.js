/**
 * The board's read side (T63d; docs/board.md, Commands): the review queue (R64 §1 rows), a worker's inbox
 * and the whole board's status, on every store. Boards are filled through the write service.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { createBoard } from '../../src/board/core/service.js';
import { inbox, reviewQueue, status } from '../../src/board/core/queries.js';
import { createMemoryStore } from '../../src/board/store/memory/index.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';
import { SCHEMA_VERSION } from '../../src/board/core/contract.js';

const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const ROSTER = [
    { name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' },
    { name: 'app', role: 'worker' }, { name: 'rv', role: 'worker' },
];
const H = (c) => c.repeat(40);
const BASE = H('0');

async function makeStore(kind, t) {
    if (kind === 'memory') return createMemoryStore();
    const dir = mkdtempSync(join(tmpdir(), 'mt-board-q-'));
    const store = createSqliteStore(join(dir, 'board.db'));
    await store.open();
    t.after(async () => { await store.close(); rmSync(dir, { recursive: true, force: true }); });
    return store;
}

function both(name, fn) {
    for (const kind of ['memory', 'sqlite']) {
        const skip = kind === 'sqlite' && !hasSqlite ? 'node:sqlite needs Node >= 22.13' : false;
        test(`[${kind}] ${name}`, { skip }, async (t) => {
            const store = await makeStore(kind, t);
            let tick = 0;
            const now = () => new Date(Date.UTC(2026, 10, 11, 0, 0, tick++)).toISOString();
            const git = { range: async (repo, base, commit) => ({ ancestor: true, commits: [commit] }) };
            const as = (actor) => createBoard({ store, roster: () => ROSTER, actor, now, git });
            await fn({ store, as });
        });
    }
}

const land = (id, commit, extra = {}) => ({
    id, repo: '/repo', commit, check: { cmd: 'npm test', result: '1/1' }, focus: ['one'], closes: [],
    report: '/r/c.md', review_report: '/r/R.md', ...extra,
});
const judge = (landing, commit, verdict, extra = {}) => ({
    landing, verdict, verified_commit: commit, report: '/r/R.md', rerun: { cmd: 'npm test', result: '1/1' }, findings: [], ...extra,
});
const full = { ticket: '/t/T.md', constraints: 'tmux -L only', base: BASE };

both('review queue: one row per open review request of the reviewer, with what R64 asks for', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'root', assignee: 'core', reviewer: 'rv', ...full });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    await as('rv').verdict(judge('T1#1', H('1'), 'changes', { findings: [{ code: 'M1', severity: 'must', summary: 's', repro: 'r' }, { code: 'L1', severity: 'low', summary: 'l', repro: 'r' }] }));
    await as('pm').finding({ id: 'R1 L1', state: 'backlog' });
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'fix', assignee: 'app', reviewer: 'rv', priority: 10, ...full });
    await as('app').take({ id: 'T1a' });
    await as('app').land(land('T1a', H('2'), { closes: ['R1 M1'] }));
    await as('app').land(land('T1a', H('3')));
    await as('pm').add({ id: 'T2', title: 'other', assignee: 'core', reviewer: 'app', ...full });
    await as('core').take({ id: 'T2' });
    await as('core').land(land('T2', H('4')));

    const q = await reviewQueue(store, ROSTER, 'rv');
    assert.deepEqual(q.queue.map((r) => r.landing.id), ['T1a#2'], 'the superseded T1a#1, T1 (changes) and T2 (app reviews) are not rv\'s');
    const row = q.queue[0];
    assert.deepEqual([row.task.id, row.task.ticket_path, row.task.constraints, row.parent.id], ['T1a', '/t/T.md', 'tmux -L only', 'T1']);
    assert.deepEqual([row.landing.commit, row.landing.base_commit, row.landing.commits, row.landing.focus, row.landing.review_report_path],
        [H('3'), BASE, [H('3')], ['one'], '/r/R.md']);
    assert.deepEqual(row.open_findings.map((f) => [f.id, f.state, f.fixed_in]), [['R1 M1', 'fixed', 'T1a#2']]);
    assert.deepEqual(row.settled_findings.map((f) => [f.id, f.state]), [['R1 L1', 'backlog']]);
    assert.deepEqual(q.incomplete, []);
    assert.deepEqual([row.next_verdict, row.verdicts.map((v) => [v.id, v.verdict])], ['R1a', [['R1', 'changes']]], 'R69 L4');
    assert.equal(row.previous_commit, H('2'), 'R70 R2: the commit of the landing this one supersedes');
    assert.equal((await reviewQueue(store, ROSTER, 'app')).queue[0].previous_commit, null);
    assert.deepEqual((await reviewQueue(store, ROSTER, 'app')).queue.map((r) => [r.landing.id, r.next_verdict]), [['T2#1', 'R2']]);
    await as('app').note({ id: 'T1a', body: 'context for the reviewer' });
    assert.deepEqual((await reviewQueue(store, ROSTER, 'rv')).queue[0].notes.map((n) => n.body), ['context for the reviewer'], 'R69 R1: a note with no "to" shows on the row');
});

both('review queue: a task without a ticket or constraints is listed as incomplete; pm judges tasks with no reviewer; priority orders', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'bare', assignee: 'core', base: BASE });
    await as('pm').assign({ id: 'T1', reviewer: 'rv' });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    const q = await reviewQueue(store, ROSTER, 'rv');
    assert.deepEqual(q.queue, []);
    assert.deepEqual(q.incomplete, [{ landing: 'T1#1', task: 'T1', missing: ['ticket_path', 'constraints'] }]);
    await as('pm').add({ id: 'T9', title: 'blank', assignee: 'app', reviewer: 'rv', ticket: '/t.md', constraints: '  ', base: BASE });
    await as('app').take({ id: 'T9' });
    const { review_report, ...noSuggestion } = land('T9', H('9'));
    await as('app').land(noSuggestion);
    assert.deepEqual((await reviewQueue(store, ROSTER, 'rv')).incomplete.map((r) => [r.task, r.missing]), [['T1', ['ticket_path', 'constraints']], ['T9', ['constraints']]],
        'R71 R2: a blank constraint is as incomplete as none; a missing review report path is not');

    await as('pm').add({ id: 'T2', title: 'low', assignee: 'core', priority: 50, ...full });
    await as('pm').add({ id: 'T3', title: 'high', assignee: 'app', priority: 5, ...full });
    for (const [who, id, c] of [['core', 'T2', '2'], ['app', 'T3', '3']]) { await as(who).take({ id }); await as(who).land(land(id, H(c))); }
    assert.deepEqual((await reviewQueue(store, ROSTER, 'pm')).queue.map((r) => r.task.id), ['T3', 'T2']);
    assert.match((await reviewQueue(store, ROSTER, 'pm')).hint, /^2 review requests wait: give each to its own sub-agent/);
    assert.match((await inbox(store, ROSTER, 'pm')).review_hint, /^2 review requests wait/);
    await as('pm').cancel({ id: 'T3' });
    assert.deepEqual((await reviewQueue(store, ROSTER, 'pm')).queue.map((r) => r.task.id), ['T2'], 'a cancelled task leaves the queue');
    assert.equal((await reviewQueue(store, ROSTER, 'pm')).hint, undefined, 'one request: no hint');
    assert.equal((await inbox(store, ROSTER, 'pm')).review_hint, undefined);
});

both('inbox: my unfinished work, my reviews, notes to me and announcements after my cursor', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'a', assignee: 'core', reviewer: 'rv', priority: 20, ...full });
    await as('pm').add({ id: 'T2', title: 'b', assignee: 'core', reviewer: 'rv', priority: 10, ...full });
    await as('pm').add({ id: 'T3', title: 'c', assignee: 'core', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T4', title: 'd', assignee: 'app', reviewer: 'core', ...full });
    await as('core').take({ id: 'T3' });
    await as('core').land(land('T3', H('3')));
    await as('app').take({ id: 'T4' });
    await as('app').land(land('T4', H('4')));
    await as('pm').note({ id: 'T1', body: 'look at x', to: ['core'] });
    await as('pm').note({ body: 'for app', to: ['app'] });
    await as('pm').announce({ body: 'rule one' });

    const first = await inbox(store, ROSTER, 'core');
    assert.deepEqual(first.tasks.map((t) => [t.id, t.state]), [['T2', 'ready'], ['T1', 'ready']], 'T3 waits on its reviewer');
    assert.deepEqual(first.review_queue.map((r) => r.landing.id), ['T4#1']);
    assert.deepEqual(first.notes.map((n) => n.body), ['look at x']);
    assert.deepEqual(first.announcements.map((a) => a.body), ['rule one']);

    await as('pm').announce({ body: 'rule two' });
    const next = await inbox(store, ROSTER, 'core', first.cursor);
    assert.deepEqual([next.notes, next.announcements.map((a) => a.body)], [[], ['rule two']]);
    assert.ok(next.cursor.announcement > first.cursor.announcement);
    assert.equal(next.cursor.board, (await store.describe()).board_id);
    const elsewhere = await inbox(store, ROSTER, 'core', { ...next.cursor, board: 'f'.repeat(32) });
    assert.deepEqual(elsewhere.announcements.map((a) => a.body), ['rule one', 'rule two'], 'R69 R2: a cursor of another board starts from the beginning');
});

both('status: in_hand leaves out a worker\'s tasks that wait on someone else (review, held)', async ({ store, as }) => {
    for (const id of ['T1', 'T2', 'T3']) await as('pm').add({ id, title: id, assignee: 'core', reviewer: 'rv', ...full });
    for (const id of ['T1', 'T2']) { await as('core').take({ id }); await as('core').land(land(id, H('1'))); }
    await as('rv').verdict(judge('T2#1', H('1'), 'hold'));
    const core = (await status(store, ROSTER)).workers.find((w) => w.name === 'core');
    assert.deepEqual(core, { name: 'core', role: 'worker', assigned: 3, in_hand: 1, reviewing: 0 });
});

const brief = (question) => ({
    question, context: 'Why now, what is stuck, what is known (docs/x.md:3).',
    options: [{ label: 'A', detail: 'd', pros: ['p'], cons: ['c'] }, { label: 'B', detail: 'd', pros: ['p1', 'p2'], cons: ['c'] }],
    recommendation: { option: 'A', reason: 'r' }, impact: 'i', refs: ['docs/x.md'],
});

both('T115: status, a family and the inbox carry the waiting task as the data contract says; answers in time order', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'root', assignee: 'core', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'sub', assignee: 'core', reviewer: 'rv', ...full });
    await as('core').take({ id: 'T1' });
    await as('core').wait({ id: 'T1', ...brief('Which layout?') });
    const all = await status(store, ROSTER);
    const t1 = all.tasks.find((t) => t.id === 'T1');
    assert.equal(t1.state, 'waiting');
    assert.deepEqual(Object.keys(t1.waiting).sort(),
        ['asked_at', 'asked_by', 'context', 'impact', 'options', 'question', 'recommendation', 'refs', 'resume_state']);
    assert.deepEqual(Object.keys(t1.waiting.options[0]).sort(), ['cons', 'detail', 'label', 'pros']);
    assert.deepEqual([t1.waiting.question, t1.waiting.asked_by, t1.waiting.resume_state], ['Which layout?', 'core', 'doing']);
    assert.equal(all.tasks.find((t) => t.id === 'T1a').waiting, null, 'null when not waiting');
    assert.equal(all.recent.at(-1).action, 'wait');
    const mine = await inbox(store, ROSTER, 'core');
    assert.deepEqual(mine.tasks.map((t) => [t.id, t.state]), [['T1', 'waiting'], ['T1a', 'ready']]);
    assert.deepEqual(mine.tasks[0].waiting, t1.waiting);

    assert.deepEqual((await status(store, ROSTER, { task: 'T1' })).answers, [], 'none answered yet');
    await as('pm').answer({ id: 'T1', chosen: 'A', answer: 'Layout A' });
    await as('pm').wait({ id: 'T1a', ...brief('Keep the old id?') });
    await as('pm').answer({ id: 'T1a', chosen: '기타', answer: 'Neither' });
    const fam = await status(store, ROSTER, { task: 'T1a' });
    assert.deepEqual(fam.answers.map(({ answered_at, brief: _, ...a }) => a), [
        { task_id: 'T1', question: 'Which layout?', chosen: 'A', answer: 'Layout A', answered_by: 'pm' },
        { task_id: 'T1a', question: 'Keep the old id?', chosen: '기타', answer: 'Neither', answered_by: 'pm' },
    ]);
    assert.deepEqual(Object.keys(fam.answers[0].brief).sort(), ['asked_at', 'asked_by', 'context', 'impact', 'options', 'question', 'recommendation', 'refs']);
    assert.deepEqual([fam.answers[0].brief.asked_by, fam.answers[1].brief.options[1].pros], ['core', ['p1', 'p2']]);
    assert.ok(fam.answers[0].answered_at <= fam.answers[1].answered_at);
    assert.equal(fam.tasks.find((t) => t.id === 'T1').state, 'doing');
});

both('T120 (R40 L3): a family\'s answers are its own, not another family\'s', async ({ store, as }) => {
    for (const id of ['T1', 'T2']) {
        await as('pm').add({ id, title: id, assignee: 'core', reviewer: 'rv', ...full });
        await as('pm').wait({ id, ...brief(`${id}: which?`) });
        await as('pm').answer({ id, chosen: 'A', answer: `${id} answer` });
    }
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'sub', assignee: 'core', reviewer: 'rv', ...full });
    assert.deepEqual((await status(store, ROSTER, { task: 'T1a' })).answers.map((a) => a.task_id), ['T1']);
    assert.deepEqual((await status(store, ROSTER, { task: 'T2' })).answers.map((a) => a.answer), ['T2 answer']);
});

both('T127: a task\'s progress in order, and each task\'s summary in the list', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'root', assignee: 'core', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'sub', assignee: 'app', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T2', title: 'other', assignee: 'core', reviewer: 'rv', ...full });
    for (const id of ['T1', 'T1a']) await as(id === 'T1' ? 'core' : 'app').take({ id });
    await as('core').progress({ id: 'T1', item: 1, note: 'parser done', done: true });
    await as('app').progress({ id: 'T1a', item: 1, note: 'sub started', done: false });
    await as('core').progress({ id: 'T1', item: 2, note: 'tests half way', done: false });
    await as('core').progress({ id: 'T1', item: 0, note: 'helped review', done: true });
    await as('core').progress({ id: 'T1', item: 3, note: 'docs done', done: true });
    const last = await as('core').progress({ id: 'T1', item: 3, note: 'docs reopened', done: false });

    const fam = await status(store, ROSTER, { task: 'T1' });
    assert.deepEqual(last.progress, fam.progress.at(-1), 'the command answers what the board keeps, time included');
    assert.deepEqual(fam.progress.map(({ at, ...p }) => p), [
        { item: 1, note: 'parser done', done: true, by: 'core' },
        { item: 2, note: 'tests half way', done: false, by: 'core' },
        { item: 0, note: 'helped review', done: true, by: 'core' },
        { item: 3, note: 'docs done', done: true, by: 'core' },
        { item: 3, note: 'docs reopened', done: false, by: 'core' },
    ], 'the asked task only, oldest first');
    assert.ok(fam.progress.every((p, i, all) => i === 0 || all[i - 1].at <= p.at));
    assert.deepEqual((await status(store, ROSTER, { task: 'T1a' })).progress.map((p) => p.note), ['sub started']);
    assert.deepEqual((await status(store, ROSTER, { task: 'T2' })).progress, []);

    const all = await status(store, ROSTER);
    const t1 = all.tasks.find((t) => t.id === 'T1').progress_summary;
    assert.deepEqual({ ...t1, last_at: 'x' }, { done_items: [1], last_note: 'docs reopened', last_at: 'x' }, 'item 0 is no item; an item done then reopened is not done');
    assert.equal(t1.last_at, fam.progress.at(-1).at);
    assert.deepEqual(all.tasks.find((t) => t.id === 'T1a').progress_summary.done_items, []);
    assert.equal(all.tasks.find((t) => t.id === 'T2').progress_summary, null);
    assert.ok(!all.recent.some((e) => e.action === 'progress'), 'progress is no change of the board (R47 S2)');
    assert.equal(all.recent.at(-1).action, 'take');
    assert.deepEqual(fam.root.progress_summary, t1, 'a family\'s tasks carry their summary too (R47 L2)');
    assert.deepEqual(fam.tasks.find((t) => t.id === 'T1a').progress_summary.last_note, 'sub started');

    // R47 L1: items in order whatever order they were done in; item 0's note is a last note
    await as('core').progress({ id: 'T1', item: 5, note: 'five', done: true });
    await as('core').progress({ id: 'T1', item: 4, note: 'four', done: true });
    await as('core').progress({ id: 'T1', item: 0, note: 'outside the items', done: false });
    const again = (await status(store, ROSTER)).tasks.find((t) => t.id === 'T1').progress_summary;
    assert.deepEqual([again.done_items, again.last_note], [[1, 4, 5], 'outside the items']);
});

both('status: every task, each worker\'s load, open findings, recent changes; or one family in full', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'root', assignee: 'core', reviewer: 'rv', ...full });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    await as('rv').verdict(judge('T1#1', H('1'), 'changes', { findings: [{ code: 'M1', severity: 'must', summary: 's', repro: 'r' }] }));
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'fix', assignee: 'app', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T2', title: 'other' });

    const all = await status(store, ROSTER);
    assert.equal(all.store.schema_version, SCHEMA_VERSION);
    assert.deepEqual(all.tasks.map((t) => [t.id, t.state]), [['T1', 'changes'], ['T1a', 'ready'], ['T2', 'new']]);
    assert.deepEqual(all.workers.find((w) => w.name === 'core'), { name: 'core', role: 'worker', assigned: 1, in_hand: 1, reviewing: 0 });
    assert.deepEqual(all.workers.find((w) => w.name === 'rv'), { name: 'rv', role: 'worker', assigned: 0, in_hand: 0, reviewing: 2 });
    assert.deepEqual(all.workers.find((w) => w.name === 'pm'), { name: 'pm', role: 'orchestrator', assigned: 0, in_hand: 0, reviewing: 1 }, 'pm judges T2, which has no reviewer');
    assert.deepEqual(all.open_findings.map((f) => f.id), ['R1 M1']);
    assert.deepEqual(all.recent.at(-1).action, 'add');
    assert.ok(all.recent.length <= 20);

    await as('pm').announce({ body: 'user decided: sqlite' });
    await as('core').note({ id: 'T1', body: 'why this way' });
    const later = await status(store, ROSTER);
    assert.deepEqual(later.announcements.map((a) => a.body), ['user decided: sqlite'], 'R69 R4');
    const fam = await status(store, ROSTER, { task: 'T1a' });
    assert.deepEqual(fam.notes.map((n) => n.body), ['why this way'], 'R69 R1');
    assert.deepEqual([fam.root.id, fam.tasks.map((t) => t.id)], ['T1', ['T1', 'T1a']]);
    assert.deepEqual(fam.landings.map((l) => l.id), ['T1#1']);
    assert.deepEqual(fam.verdicts.map((v) => [v.id, v.verdict]), [['R1', 'changes']]);
    assert.deepEqual(fam.findings.map((f) => f.id), ['R1 M1']);
    await assert.rejects(status(store, ROSTER, { task: 'T9' }), (err) => err.code === 'not-found');
});

both('T198: a backlog finding of another family a landing names in closes is in its review row, still backlog', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'one', assignee: 'core', reviewer: 'rv', ...full });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    await as('rv').verdict(judge('T1#1', H('1'), 'changes', { findings: [{ code: 'L1', severity: 'low', summary: 's', repro: 'r' }] }));
    await as('pm').finding({ id: 'R1 L1', state: 'backlog' });
    await as('pm').add({ id: 'T2', title: 'two', assignee: 'app', reviewer: 'rv', ...full });
    await as('app').take({ id: 'T2' });
    await as('app').land(land('T2', H('2'), { closes: ['R1 L1'] }));

    const row = (await reviewQueue(store, ROSTER, 'rv')).queue.find((r) => r.landing.id === 'T2#1');
    assert.deepEqual(row.closes_outside.map((f) => [f.id, f.task_id, f.state]), [['R1 L1', 'T1', 'backlog']]);
});

both('a fix outside the family: the landing\'s review row lists it; the family read says which landing and whether approved (T87)', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'one', assignee: 'core', reviewer: 'rv', ...full });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    await as('rv').verdict(judge('T1#1', H('1'), 'changes', { findings: [{ code: 'S1', severity: 'should', summary: 's', repro: 'r' }] }));
    await as('pm').add({ id: 'T2', title: 'two', assignee: 'app', reviewer: 'rv', ...full });
    await as('app').take({ id: 'T2' });
    await as('app').land(land('T2', H('2'), { closes: ['R1 S1'] }));

    const row = (await reviewQueue(store, ROSTER, 'rv')).queue.find((r) => r.landing.id === 'T2#1');
    assert.deepEqual(row.closes_outside.map((f) => [f.id, f.task_id, f.state, f.fixed_in]), [['R1 S1', 'T1', 'fixed', 'T2#1']]);
    assert.deepEqual(row.open_findings, [], 'T2\'s family has none of its own');
    assert.deepEqual((await status(store, ROSTER, { task: 'T1' })).fixed_elsewhere, [{ landing: 'T2#1', task_id: 'T2', approved: false }]);
    assert.deepEqual((await status(store, ROSTER)).open_findings.map((f) => f.id), ['R1 S1'], 'still open until T2#1 is approved');

    await as('rv').verdict(judge('T2#1', H('2'), 'approve'));
    assert.deepEqual((await status(store, ROSTER, { task: 'T1' })).fixed_elsewhere, [{ landing: 'T2#1', task_id: 'T2', approved: true }]);
    assert.deepEqual((await status(store, ROSTER)).open_findings, []);
    assert.deepEqual((await status(store, ROSTER, { task: 'T2' })).fixed_elsewhere, [], 'the fixing family has nothing fixed elsewhere');
});

both('history: how often a task came back, its last event, since when it is in its state (T156)', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'one', assignee: 'core', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T2', title: 'two', assignee: 'app', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T3', title: 'three' });
    // the log's own time of an event: a row's created_at is read from the clock apart from it
    const logged = async (action, ref) => (await store.logOf([ref])).findLast((e) => e.action === action).at;
    const fresh = (await status(store, ROSTER)).tasks.find((t) => t.id === 'T3');
    const added = await logged('add', 'T3');
    assert.deepEqual(fresh.history, {
        landings: 0, verdicts: { approve: 0, changes: 0, hold: 0 },
        last_event: { action: 'add', verdict: null, by: 'pm', at: added, state_from: null, state_to: 'new' },
        state_since: added, last_progress_by: null, cancelled_from: null,
    }, 'a task nobody touched');

    // changes twice, then the third landing
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    await as('rv').verdict(judge('T1#1', H('1'), 'changes'));
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('2')));
    await as('rv').verdict(judge('T1#2', H('2'), 'changes'));
    await as('core').take({ id: 'T1' });
    await as('core').progress({ id: 'T1', item: 1, note: 'fixing', done: false });
    await as('core').land(land('T1', H('3')));
    const third = await logged('land', 'T1#3');

    const all = await status(store, ROSTER);
    const t1 = all.tasks.find((t) => t.id === 'T1');
    assert.equal(t1.history.landings, 3);
    assert.deepEqual(t1.history.verdicts, { approve: 0, changes: 2, hold: 0 });
    assert.deepEqual(t1.history.last_event, { action: 'land', verdict: null, by: 'core', at: third, state_from: 'doing', state_to: 'review' });
    assert.equal(t1.history.state_since, third);
    assert.equal(t1.history.last_progress_by, 'core');
    assert.ok(t1.history.state_since > t1.progress_summary.last_at, 'a progress report is no event and enters no state');
    assert.equal(all.tasks.find((t) => t.id === 'T2').history.landings, 0, 'another task\'s landings are not counted');

    // a landing again while in review enters no state; the family read carries the same values
    await as('core').land(land('T1', H('4')));
    const fam = await status(store, ROSTER, { task: 'T1' });
    assert.equal(fam.root.history.landings, 4);
    assert.equal(fam.root.history.state_since, third);
    assert.deepEqual(fam.tasks[0].history, (await status(store, ROSTER)).tasks.find((t) => t.id === 'T1').history);

    const done = await logged('verdict', (await as('rv').verdict(judge('T1#4', H('4'), 'approve'))).verdict.id);
    const approved = (await status(store, ROSTER)).tasks.find((t) => t.id === 'T1').history;
    assert.deepEqual(approved.verdicts, { approve: 1, changes: 2, hold: 0 });
    assert.deepEqual(approved.last_event, { action: 'verdict', verdict: 'approve', by: 'rv', at: done, state_from: 'review', state_to: 'done' });

    // cancelled: from the state it was in, or the state it waited in
    await as('app').take({ id: 'T2' });
    await as('app').wait({
        id: 'T2', question: 'A or B?', context: 'c', impact: 'i', recommendation: { option: 'A', reason: 'r' },
        options: [{ label: 'A', pros: ['p'], cons: ['c'] }, { label: 'B', pros: ['p'], cons: ['c'] }],
    });
    await as('pm').cancel({ id: 'T2', reason: 'no longer needed' });
    await as('pm').cancel({ id: 'T3' });
    const after = (await status(store, ROSTER)).tasks;
    assert.equal(after.find((t) => t.id === 'T2').history.cancelled_from, 'doing', 'the state it waited in');
    assert.equal(after.find((t) => t.id === 'T2').history.last_event.action, 'cancel');
    assert.equal(after.find((t) => t.id === 'T3').history.cancelled_from, 'new');
});

both('edit: a task in review with no constraints leaves `incomplete` once pm fills them in; an edit is no event of its history (T158)', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'one', assignee: 'core', reviewer: 'rv', ticket: '/t/T.md', base: BASE });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    assert.deepEqual(await reviewQueue(store, ROSTER, 'rv'), { queue: [], incomplete: [{ landing: 'T1#1', task: 'T1', missing: ['constraints'] }] });
    const before = (await status(store, ROSTER)).tasks[0].history;

    await as('pm').edit({ id: 'T1', constraints: 'tmux -L only' });
    const q = await reviewQueue(store, ROSTER, 'rv');
    assert.deepEqual([q.incomplete, q.queue.map((r) => [r.landing.id, r.task.constraints])], [[], [['T1#1', 'tmux -L only']]]);
    const all = await status(store, ROSTER);
    assert.deepEqual(all.tasks[0].history, before, 'the last event is still the landing, and the task entered no state');
    assert.deepEqual([all.recent.at(-1).action, Object.keys(all.recent.at(-1).detail.changed)], ['edit', ['constraints']], 'what was changed shows in the recent changes');
});

both('a document task in board-status: its landing has every field a landing has, and the task says what it delivers (T158)', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'advice', assignee: 'core', reviewer: 'rv', deliverable: 'document', ticket: '/t/T.md', constraints: '없음' });
    await as('pm').add({ id: 'T2', title: 'code', assignee: 'core', reviewer: 'rv', ...full });
    for (const id of ['T1', 'T2']) await as('core').take({ id });
    await as('core').land({ id: 'T1', check: { cmd: 'read', result: 'ok' }, focus: ['one'], closes: [], report: '/r/a.md', review_report: '/r/R.md' });
    await as('core').land(land('T2', H('2')));
    assert.deepEqual((await reviewQueue(store, ROSTER, 'rv')).queue.map((r) => [r.landing.id, r.landing.commit, r.previous_commit]), [['T1#1', '', null], ['T2#1', H('2'), null]]);
    await as('rv').verdict({ landing: 'T1#1', verdict: 'changes', report: '/r/R.md', rerun: { cmd: 'read', result: 'ok' }, findings: [] });
    // unmarked, it lands a commit: the reviewer saw no commit of it before (R8 L2)
    await as('pm').edit({ id: 'T1', deliverable: 'commits', base: BASE });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    assert.equal((await reviewQueue(store, ROSTER, 'rv')).queue.find((r) => r.task.id === 'T1').previous_commit, null);
    await as('pm').add({ id: 'T3', title: 'advice', assignee: 'core', reviewer: 'rv', deliverable: 'document', ticket: '/t/T.md', constraints: '없음' });
    await as('core').take({ id: 'T3' });
    await as('core').land({ id: 'T3', check: { cmd: 'read', result: 'ok' }, focus: ['one'], closes: [], report: '/r/a.md', review_report: '/r/R.md' });
    await as('rv').verdict({ landing: 'T3#1', verdict: 'approve', report: '/r/R.md', rerun: { cmd: 'read', result: 'ok' }, findings: [] });

    const all = await status(store, ROSTER);
    assert.deepEqual(all.tasks.map((t) => [t.id, t.state, t.deliverable]), [['T1', 'review', null], ['T2', 'review', null], ['T3', 'done', 'document']]);
    assert.deepEqual(all.tasks[2].history.landings, 1);
    const fam = await status(store, ROSTER, { task: 'T3' });
    const code = (await status(store, ROSTER, { task: 'T2' })).landings[0];
    assert.deepEqual(Object.keys(fam.landings[0]), Object.keys(code), 'the same fields as a landing of commits');
    for (const k of ['repo', 'commit', 'base_commit', 'commits', 'left_out']) assert.equal(typeof fam.landings[0][k], typeof code[k], `${k} keeps its type`);
    assert.deepEqual([fam.landings[0].commit, fam.landings[0].commits, fam.verdicts[0].verified_commit], ['', [], '']);
});
