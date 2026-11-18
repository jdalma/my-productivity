/**
 * Decisions asked of the user (T146): board-ask, the decisions of board-wait, and the one list board-status and
 * board-inbox give of them, on every store.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { createBoard } from '../../src/board/core/service.js';
import { inbox, status } from '../../src/board/core/queries.js';
import { createMemoryStore } from '../../src/board/store/memory/index.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';

const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const STORES = {
    memory: async () => createMemoryStore(),
    sqlite: async (t) => {
        const dir = mkdtempSync(join(tmpdir(), 'mt-board-dec-'));
        const store = createSqliteStore(join(dir, 'board.db'));
        await store.open();
        t.after(async () => { await store.close(); rmSync(dir, { recursive: true, force: true }); });
        return store;
    },
};

function both(name, fn) {
    for (const [kind, make] of Object.entries(STORES)) {
        const skip = kind === 'sqlite' && !hasSqlite ? 'node:sqlite needs Node >= 22.13' : false;
        test(`[${kind}] ${name}`, { skip }, async (t) => fn(await setup(await make(t))));
    }
}

const ROSTER = [{ name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' }, { name: 'rv', role: 'worker' }];

async function setup(store) {
    let tick = 0;
    const now = () => new Date(Date.UTC(2026, 10, 16, 0, 0, tick++)).toISOString();
    const sent = [];
    const as = (actor) => createBoard({
        store, roster: () => ROSTER, actor, now, git: { range: async () => ({ ancestor: true, commits: [] }) },
        notify: async (to, ref, action) => { sent.push({ to: [...to].sort(), ref, action }); return []; },
    });
    return { store, as, sent, list: async () => (await status(store, ROSTER)).decisions };
}

const option = (label) => ({ label, detail: `${label} 방식`, pros: [`${label}의 장점`], cons: [`${label}의 단점`] });
const brief = (question, extra = {}) => ({
    question, context: '지금 상태', options: [option('A'), option('B')],
    recommendation: { option: 'A', reason: '더 단순하다' }, impact: '다음 작업의 범위', ...extra,
});
const code = (c) => (err) => err.code === c;

both('several open decisions on one task, and the task goes on', async ({ as, sent, list }) => {
    await as('pm').add({ id: 'T1', title: '계획서', assignee: 'core', reviewer: 'rv' });
    const d1 = await as('core').ask(brief('범위는?', { tasks: ['T1'] }));
    const d2 = await as('core').ask(brief('이관 방식은?', { tasks: ['T1'] }));
    assert.deepEqual([d1.decision.id, d2.decision.id], ['D#1', 'D#2']);
    assert.deepEqual(sent.filter((s) => s.action === 'ask').map((s) => [s.ref, s.to]), [['D#1', ['pm']], ['D#2', ['pm']]]);
    // the task moves with both open: taken, then waiting on a decision of its own
    assert.equal((await as('core').take({ id: 'T1' })).task.state, 'doing');
    assert.equal((await as('core').wait({ id: 'T1', ...brief('이름은?') })).task.state, 'waiting');
    const open = (await list()).filter((d) => d.state === 'open');
    assert.deepEqual(open.map((d) => [d.id, d.task_id, d.tasks]), [['D#1', null, ['T1']], ['D#2', null, ['T1']], ['T1:1', 'T1', ['T1']]]);
});

both('a decision with no task: asked by a worker, answered by pm, and the asker is told', async ({ as, sent, list }) => {
    await as('core').ask(brief('다음 분기 범위는?'));
    await assert.rejects(as('core').answer({ id: 'D#1', chosen: 'A', answer: '좋다' }), code('forbidden'));
    const r = await as('pm').answer({ id: 'D#1', chosen: 'B', answer: '사용자: B로 간다' });
    assert.equal(r.decision.state, 'answered');
    assert.deepEqual(sent.at(-1), { to: ['core'], ref: 'D#1', action: 'answer' });
    const [d] = await list();
    assert.equal(d.state, 'answered');
    assert.equal(d.task_id, null);
    assert.deepEqual(d.tasks, []);
    assert.deepEqual([d.chosen, d.answer, d.answered_by, d.asked_by], ['B', '사용자: B로 간다', 'pm', 'core']);
    assert.deepEqual(d.options.map((o) => o.label), ['A', 'B']);
    await assert.rejects(as('pm').answer({ id: 'D#1', chosen: 'A', answer: '다시' }), code('invalid-transition'));
    await assert.rejects(as('pm').answer({ id: 'D#9', chosen: 'A', answer: '없음' }), code('not-found'));
});

both('a decision the user already made is recorded at once by pm, with one option', async ({ as, sent, list }) => {
    const one = { ...brief('저장소 공개 여부'), options: [option('공개')], recommendation: { option: '공개', reason: '사용자가 정함' } };
    await assert.rejects(as('core').ask({ ...one, answered: { chosen: '공개', answer: '공개로 한다' } }), code('forbidden'));
    await assert.rejects(as('core').ask(one), code('invalid'), 'an open question needs two options');
    const r = await as('pm').ask({ ...one, answered: { chosen: '공개', answer: '사용자가 먼저 정했다' } });
    assert.equal(r.decision.state, 'answered');
    assert.equal(sent.filter((s) => s.ref === 'D#1').length, 0, 'nobody to tell');
    const [d] = await list();
    assert.deepEqual([d.state, d.chosen, d.answer, d.asked_by, d.answered_by], ['answered', '공개', '사용자가 먼저 정했다', 'pm', 'pm']);
});

both('pm withdraws a decision no longer needed with 철회, and 철회 is no option label', async ({ as, list }) => {
    await as('core').ask(brief('예전 질문'));
    await as('pm').answer({ id: 'D#1', chosen: '철회', answer: '계획이 바뀌어 필요 없다' });
    assert.deepEqual((await list()).map((d) => [d.state, d.chosen]), [['answered', '철회']]);
    await assert.rejects(as('core').ask({ ...brief('x'), options: [option('철회'), option('B')] }), code('invalid'));
    await assert.rejects(as('core').ask(brief('x', { tasks: ['T404'] })), code('not-found'));
});

both('the list holds task waits and decisions of board-ask in the order asked, a wait keeping its id', async ({ as, list }) => {
    await as('pm').add({ id: 'T1', title: '구현', assignee: 'core', reviewer: 'rv' });
    await as('pm').add({ id: 'T2', title: '이관', assignee: 'core', reviewer: 'rv' });
    await as('core').wait({ id: 'T1', ...brief('첫 질문') });
    await as('core').ask(brief('작업 없는 질문'));
    await as('pm').answer({ id: 'T1', chosen: 'A', answer: 'A로' });
    await as('core').wait({ id: 'T1', ...brief('두 번째 질문') });
    await as('core').wait({ id: 'T2', ...brief('취소될 질문') });
    await as('pm').cancel({ id: 'T2', reason: '범위에서 뺌' });
    const all = await list();
    assert.deepEqual(all.map((d) => [d.id, d.state, d.question]), [
        ['T1:1', 'answered', '첫 질문'], ['D#1', 'open', '작업 없는 질문'], ['T1:2', 'open', '두 번째 질문'], ['T2:1', 'answered', '취소될 질문'],
    ]);
    assert.deepEqual(all.map((d) => d.asked_at), [...all.map((d) => d.asked_at)].sort());
    const [first, , second, cancelled] = all;
    assert.deepEqual([first.chosen, first.context, first.options.length], ['A', '지금 상태', 2], 'an answered wait keeps its brief');
    assert.equal(second.recommendation.option, 'A', 'an open wait reads its brief from the task');
    assert.deepEqual([cancelled.chosen, cancelled.answer], ['철회', '작업이 취소되었습니다: 범위에서 뺌']);
    assert.deepEqual((await list()).map((d) => d.id), all.map((d) => d.id), 'the same ids on every call');
});

both('board-inbox: pm sees every open decision, the asker the answers to its questions once', async ({ store, as }) => {
    await as('core').ask(brief('질문 하나'));
    await as('rv').ask(brief('질문 둘'));
    const pm = await inbox(store, ROSTER, 'pm');
    assert.deepEqual(pm.decisions.open.map((d) => d.id), ['D#1', 'D#2']);
    assert.deepEqual((await inbox(store, ROSTER, 'core')).decisions.open.map((d) => d.id), ['D#1']);
    await as('pm').answer({ id: 'D#1', chosen: 'A', answer: 'A' });
    const first = await inbox(store, ROSTER, 'core');
    assert.deepEqual(first.decisions.answered.map((d) => [d.id, d.chosen]), [['D#1', 'A']]);
    assert.equal('seq' in first.decisions.answered[0], false);
    assert.deepEqual((await inbox(store, ROSTER, 'core', first.cursor)).decisions.answered, []);
    assert.deepEqual((await inbox(store, ROSTER, 'rv')).decisions.answered, []);
});

both('R3 M1: a task named D1 waits and is answered as before, apart from the decision D#1', async ({ as, list }) => {
    await as('pm').add({ id: 'D1', title: '이름이 D1인 작업', assignee: 'core', reviewer: 'rv' });
    await as('core').wait({ id: 'D1', ...brief('작업 D1의 질문') });
    assert.equal((await as('core').ask(brief('작업 없는 질문'))).decision.id, 'D#1');
    const r = await as('pm').answer({ id: 'D1', chosen: 'A', answer: 'A로' });
    assert.equal(r.task.state, 'ready', 'the task D1 goes back to where it waited from');
    assert.deepEqual((await list()).map((d) => [d.id, d.task_id, d.state]), [['D1:1', 'D1', 'answered'], ['D#1', null, 'open']]);
});

both('R3 S1: a wait its task was cancelled out of keeps its brief in the list', async ({ as, list }) => {
    await as('pm').add({ id: 'T1', title: '취소될 작업', assignee: 'core', reviewer: 'rv' });
    await as('core').wait({ id: 'T1', ...brief('취소될 질문') });
    await as('pm').cancel({ id: 'T1', reason: '범위에서 뺌' });
    const [d] = await list();
    assert.deepEqual([d.state, d.chosen, d.context, d.options.map((o) => o.label), d.recommendation.option, d.impact],
        ['answered', '철회', '지금 상태', ['A', 'B'], 'A', '다음 작업의 범위']);
});

both('R3 L2: a cursor from before T146 gets the answers to its board-ask questions, not again the waits answered before', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: '작업', assignee: 'core', reviewer: 'rv' });
    await as('core').wait({ id: 'T1', ...brief('예전 질문') });
    await as('pm').answer({ id: 'T1', chosen: 'A', answer: 'A' });
    await as('core').ask(brief('새 질문'));
    await as('pm').answer({ id: 'D#1', chosen: 'B', answer: 'B' });
    const { cursor: { board } } = await inbox(store, ROSTER, 'core');
    const legacy = await inbox(store, ROSTER, 'core', { board, note: 0, announcement: 0 });
    assert.deepEqual(legacy.decisions.answered.map((d) => d.id), ['D#1']);
    assert.deepEqual((await inbox(store, ROSTER, 'core')).decisions.answered.map((d) => d.id), ['T1:1', 'D#1'], 'no cursor: all of them');
});

both('R4a L1: a wait is asked at one time, the task\'s brief and the decision list alike', async ({ store, as, list }) => {
    await as('pm').add({ id: 'T1', title: '작업', assignee: 'core', reviewer: 'rv' });
    await as('core').wait({ id: 'T1', ...brief('질문') });
    const [d] = await list();
    assert.equal(d.asked_at, (await store.get('task', 'T1')).waiting.asked_at);
});

const edit = (b, input) => b['decision-edit'](input);

both('T203: an open decision is edited in place: only the fields given change, and the list says how often and by whom', async ({ store, as, list }) => {
    await as('pm').add({ id: 'T1', title: '계획서', assignee: 'core', reviewer: 'rv' });
    await as('pm').add({ id: 'T2', title: '구현', assignee: 'core', reviewer: 'rv' });
    await as('core').ask(brief('범위는?', { tasks: ['T1'], refs: ['docs/a.md'] }));
    const [before] = await list();
    assert.deepEqual([before.edits, before.edited_by, before.edited_at], [0, null, null]);

    const r1 = await edit(as('core'), { id: 'D#1', question: '범위는 어디까지인가?' });
    assert.deepEqual(r1.changed, ['question']);
    assert.equal(r1.decision.brief.question, '범위는 어디까지인가?');
    const r2 = await edit(as('pm'), {
        id: 'D#1', options: [option('A'), option('B'), option('C')], recommendation: { option: 'C', reason: '논의 결과' }, tasks: ['T1', 'T2'],
    });
    assert.deepEqual(r2.changed, ['options', 'recommendation', 'tasks']);

    const [d] = await list();
    assert.deepEqual([d.id, d.state, d.question, d.context, d.impact, d.refs], ['D#1', 'open', '범위는 어디까지인가?', '지금 상태', '다음 작업의 범위', ['docs/a.md']]);
    assert.deepEqual([d.options.map((o) => o.label), d.recommendation, d.tasks], [['A', 'B', 'C'], { option: 'C', reason: '논의 결과' }, ['T1', 'T2']]);
    assert.deepEqual([d.asked_by, d.asked_at], [before.asked_by, before.asked_at], 'who asked and when stay');
    assert.equal(d.edits, 2);
    assert.equal(d.edited_by, 'pm');
    assert.equal(d.edited_at, (await store.get('decision', 'D#1')).updated_at);
    const open = (await inbox(store, ROSTER, 'core')).decisions.open;
    assert.deepEqual(open.map((o) => [o.id, o.question, o.edits, o.edited_by]), [['D#1', '범위는 어디까지인가?', 2, 'pm']]);
});

both('T203: each edit is logged with who, when, the fields changed and what they were', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: '계획서', assignee: 'core', reviewer: 'rv' });
    await as('core').ask(brief('범위는?'));
    await edit(as('core'), { id: 'D#1', question: '범위는 어디까지인가?', tasks: ['T1'] });
    await edit(as('pm'), { id: 'D#1', impact: '일정' });
    const log = (await store.logOf(['D#1'])).filter((e) => e.action === 'edit');
    assert.deepEqual(log.map((e) => [e.actor, e.kind, e.detail.changed]), [
        ['core', 'decision', { question: { from: '범위는?', to: '범위는 어디까지인가?' }, tasks: { from: [], to: ['T1'] } }],
        ['pm', 'decision', { impact: { from: '다음 작업의 범위', to: '일정' } }],
    ]);
    assert.equal(log[1].at, (await store.get('decision', 'D#1')).updated_at);
});

both('T203: only an open decision is edited; an answered or a withdrawn one is refused with the reason', async ({ as, list }) => {
    await as('core').ask(brief('답할 질문'));
    await as('core').ask(brief('철회할 질문'));
    await as('pm').answer({ id: 'D#1', chosen: 'A', answer: 'A로' });
    await as('pm').answer({ id: 'D#2', chosen: '철회', answer: '필요 없다' });
    await assert.rejects(edit(as('pm'), { id: 'D#1', question: '바꾼 질문' }), (err) => err.code === 'invalid-transition' && /D#1 is already answered/.test(err.message));
    await assert.rejects(edit(as('core'), { id: 'D#2', question: '바꾼 질문' }), (err) => err.code === 'invalid-transition' && /D#2 is withdrawn/.test(err.message));
    await assert.rejects(edit(as('pm'), { id: 'D#9', question: '없는 결정' }), code('not-found'));
    assert.deepEqual((await list()).map((d) => [d.question, d.edits]), [['답할 질문', 0], ['철회할 질문', 0]]);
});

both('T203: pm and the worker who asked edit a decision; another worker is refused', async ({ as, sent, list }) => {
    await as('core').ask(brief('범위는?'));
    await assert.rejects(edit(as('rv'), { id: 'D#1', question: '남의 질문' }), code('forbidden'));
    assert.equal((await list())[0].question, '범위는?');
    await edit(as('core'), { id: 'D#1', question: '올린 워커가 고침' });
    assert.deepEqual(sent.at(-1), { to: ['pm'], ref: 'D#1', action: 'edit' }, 'pm is told of the asker\'s edit');
    await edit(as('pm'), { id: 'D#1', question: 'pm이 고침' });
    assert.deepEqual(sent.at(-1), { to: ['core'], ref: 'D#1', action: 'edit' }, 'the asker is told of pm\'s edit');
});

both('T203: an edit is checked as board-ask checks a brief, against the brief it leaves', async ({ as, list }) => {
    await as('core').ask(brief('범위는?'));
    const messageOf = (p) => p.then(() => assert.fail('not refused'), (err) => { assert.equal(err.code, 'invalid'); return err.message; });
    const bad = [
        { options: [option('A')] },
        { options: [option('A'), option('A')] },
        { options: [option('A'), { label: 'B', pros: [], cons: ['x'] }] },
        { options: [option('A'), option('철회')] },
        { question: '  ' },
        { recommendation: { option: 'Z', reason: '없는 선택지' } },
        { refs: ['ok', 3] },
    ];
    for (const fields of bad) {
        assert.equal(await messageOf(edit(as('core'), { id: 'D#1', ...fields })), await messageOf(as('core').ask({ ...brief('범위는?'), ...fields })));
    }
    assert.match(await messageOf(edit(as('core'), { id: 'D#1', options: [option('B'), option('C')] })), /recommendation\.option must be one of B, C, or null/);
    await assert.rejects(edit(as('core'), { id: 'D#1', tasks: ['T404'] }), code('not-found'));
    await assert.rejects(edit(as('core'), { id: 'D#1' }), code('invalid'), 'nothing given');
    await assert.rejects(edit(as('core'), { id: 'D#1', question: '범위는?' }), code('invalid'), 'nothing changes');
    await assert.rejects(edit(as('core'), { id: 'D#1', answer: 'A' }), code('invalid'), 'not a field of the brief');
    assert.equal((await list())[0].edits, 0);
});

both('T203: an option stored without a detail stays so when another field is edited', async ({ as, list }) => {
    const { detail: _, ...bare } = option('A');
    await as('core').ask({ ...brief('범위는?'), options: [bare, option('B')] });
    await edit(as('core'), { id: 'D#1', impact: '일정' });
    const [d] = await list();
    assert.deepEqual([d.options[0].detail, d.impact], ['', '일정']);
});

both('T203: a waiting task\'s decision is edited by its task id, by pm or the worker who asked', async ({ store, as, sent, list }) => {
    await as('pm').add({ id: 'T1', title: '구현', assignee: 'core', reviewer: 'rv' });
    await assert.rejects(edit(as('core'), { id: 'T1', question: '기다리지 않는 작업' }), code('invalid-transition'));
    await as('core').wait({ id: 'T1', ...brief('첫 질문') });
    await as('pm').answer({ id: 'T1', chosen: 'A', answer: 'A로' });
    await as('core').wait({ id: 'T1', ...brief('두 번째 질문') });
    const { waiting: asked, updated_at: since } = await store.get('task', 'T1');
    await assert.rejects(edit(as('rv'), { id: 'T1', question: '리뷰어가 고침' }), code('forbidden'));
    await assert.rejects(edit(as('core'), { id: 'T1', tasks: ['T1'] }), code('invalid'), 'a wait serves its own task');

    const r = await edit(as('pm'), { id: 'T1', question: '두 번째 질문, 고침', refs: ['docs/b.md'] });
    assert.deepEqual(r.changed, ['question', 'refs']);
    assert.deepEqual(sent.at(-1), { to: ['core'], ref: 'T1:2', action: 'edit' }, 'the notice names the decision as the list does');
    assert.deepEqual((await store.logOf(['T1:2'])).map((e) => [e.kind, e.action, e.detail.changed.question.from]), [['decision', 'edit', '두 번째 질문']]);
    const task = await store.get('task', 'T1');
    assert.deepEqual(task.waiting, { ...asked, question: '두 번째 질문, 고침', refs: ['docs/b.md'] }, 'who asked, when and the state to go back to stay');
    assert.deepEqual([task.state, task.updated_at], ['waiting', since], 'since when it waits stays');
    assert.deepEqual((await list()).map((d) => [d.id, d.question, d.edits, d.edited_by]), [['T1:1', '첫 질문', 0, null], ['T1:2', '두 번째 질문, 고침', 1, 'pm']]);
    const fam = await status(store, ROSTER, { task: 'T1' });
    assert.equal(fam.root.history.last_event.action, 'wait', 'an edit of the question is no event of the task');

    await as('pm').answer({ id: 'T1', chosen: 'B', answer: 'B로' });
    const [, second] = await list();
    assert.deepEqual([second.state, second.question, second.edits, second.edited_by], ['answered', '두 번째 질문, 고침', 1, 'pm'], 'the answered wait keeps what was edited');
    await assert.rejects(edit(as('pm'), { id: 'T1', question: '답한 뒤' }), code('invalid-transition'));
});
