/**
 * Goal order (T210; plan research/my-team-goal-order-plan.md 2.1-2.3, cases of section 4).
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { annotate, GOAL_TEMPLATE, ORDER_FORMATS, parseOrder, waves } from '../../src/board/core/goal-order.js';

const order = (...lines) => `# G1 goal\n\n## 순서\n${lines.map((l) => `- ${l}`).join('\n')}\n`;
const refsOf = (md) => { const o = parseOrder(md); return waves(o.edges, o.listed).waves.map((w) => w.map((n) => n.ref)); };
const task = (id, state, done_items = []) => ({ id, title: `title ${id}`, state, progress_summary: { done_items } });
const nodeOf = (result, ref) => result.waves.flat().find((n) => n.ref === ref);

const DASHBOARD = `# G3 대시보드: 사용량·인사이트

## 요청
"거시적인 의미의 대시보드"

## 순서
- T178 -> T179, T180
- T179, T180 -> T181, T177
- T181:1 -> T177:4-7
- T177, T181 -> T192
`;

test('a straight line gives one task per wave', () => {
    assert.deepEqual(refsOf(order('A -> B', 'B -> C')), [['A'], ['B'], ['C']]);
});

test('tasks with the same predecessors share a wave', () => {
    assert.deepEqual(refsOf(order('A -> B, C', 'B, C -> D')), [['A'], ['B', 'C'], ['D']]);
});

test('T222: a list line names tasks in no order, all in the first wave', () => {
    const md = order('A, B', 'C');
    assert.deepEqual(parseOrder(md).invalid, []);
    assert.deepEqual(refsOf(md), [['A', 'B', 'C']]);
});

test('T222: list lines and order lines mix; a task listed again keeps its predecessors', () => {
    const md = order('A -> B', 'C, D', 'B, A');
    assert.deepEqual(parseOrder(md).invalid, []);
    assert.deepEqual(refsOf(md), [['A', 'C', 'D'], ['B']]);
    const o = parseOrder(md);
    const r = annotate(waves(o.edges, o.listed).waves, [task('A', 'ready'), task('B', 'ready'), task('C', 'ready')]);
    assert.deepEqual(r.ready_now, ['A', 'C']);
    assert.equal(nodeOf(r, 'B').status, 'waiting');
    assert.deepEqual(r.unregistered, ['D']);
});

test('success 1: the dashboard goal gives five waves, the item range a node of its own', () => {
    assert.deepEqual(refsOf(DASHBOARD), [['T178'], ['T179', 'T180'], ['T181', 'T177'], ['T177:4-7'], ['T192']]);
    const range = waves(parseOrder(DASHBOARD).edges).waves[3][0];
    assert.deepEqual(range.items, [4, 5, 6, 7]);
    // the range gets what its body gets, plus its own predecessor
    assert.deepEqual(range.after.map((r) => r.ref), ['T179', 'T180', 'T181:1']);
});

test('success 2: T181 item 1 done makes T177:4-7 ready now', () => {
    const graph = waves(parseOrder(DASHBOARD).edges).waves;
    const board = (t181Done) => [
        task('T178', 'done'), task('T179', 'done'), task('T180', 'done'),
        task('T181', 'in_progress', t181Done), task('T177', 'in_progress'), task('T192', 'ready'),
    ];
    const before = annotate(graph, board([]));
    assert.equal(nodeOf(before, 'T177:4-7').status, 'waiting');
    assert.deepEqual(nodeOf(before, 'T177:4-7').blocked_by, [{ ref: 'T181:1', state: 'in_progress' }]);
    assert.deepEqual(before.ready_now, ['T181', 'T177']);

    const after = annotate(graph, board([1]));
    assert.equal(nodeOf(after, 'T177:4-7').status, 'ready_now');
    assert.deepEqual(after.ready_now, ['T181', 'T177', 'T177:4-7']);
    // a whole task before counts only when approved: T192 still waits on both
    assert.deepEqual(nodeOf(after, 'T192').blocked_by.map((b) => b.ref), ['T177', 'T181']);
});

test('an item ref counts as complete when its task is done, a range node is done when its items are', () => {
    const graph = waves(parseOrder(order('A:1 -> B:2-3')).edges).waves;
    const r = annotate(graph, [task('A', 'done'), task('B', 'in_progress', [2, 3])]);
    assert.equal(nodeOf(r, 'B:2-3').status, 'done');
    assert.equal(nodeOf(r, 'B').status, 'ready_now');
});

test('a cycle gives its path and no waves', () => {
    const r = waves(parseOrder(order('A -> B', 'B -> C', 'C -> A', 'X -> A')).edges);
    assert.deepEqual(r.waves, []);
    assert.deepEqual(r.cycle, ['A', 'B', 'C', 'A']);
});

test('a whole task before its own range is a cycle', () => {
    assert.deepEqual(waves(parseOrder(order('T1 -> T1:2')).edges).cycle, ['T1:2', 'T1:2']);
});

test('ids not on the board are unregistered, not an error, and block what follows', () => {
    const graph = waves(parseOrder(order('A -> T999')).edges).waves;
    const r = annotate(graph, [task('A', 'ready')]);
    assert.deepEqual(r.unregistered, ['T999']);
    assert.equal(nodeOf(r, 'T999').status, 'unregistered');
    assert.equal(nodeOf(r, 'A').status, 'ready_now');

    const r2 = annotate(waves(parseOrder(order('T999 -> A')).edges).waves, [task('A', 'ready')]);
    assert.deepEqual(nodeOf(r2, 'A').blocked_by, [{ ref: 'T999', state: 'unregistered' }]);
    assert.equal(nodeOf(r2, 'A').status, 'waiting');
});

test('a cancelled predecessor is not complete and shows in blocked_by; a cancelled task is not ready', () => {
    const graph = waves(parseOrder(order('A -> B', 'C -> D')).edges).waves;
    const r = annotate(graph, [task('A', 'cancelled'), task('B', 'ready'), task('C', 'done'), task('D', 'cancelled')]);
    assert.equal(nodeOf(r, 'B').status, 'waiting');
    assert.deepEqual(nodeOf(r, 'B').blocked_by, [{ ref: 'A', state: 'cancelled' }]);
    assert.equal(nodeOf(r, 'D').status, 'cancelled');
    assert.deepEqual(r.ready_now, []);
});

test('a goal without the order section is not computed', () => {
    const r = parseOrder('# G1\n\n## 요청\n- A -> B\n\n```\n## 순서\n- A -> B\n```\n');
    assert.deepEqual(r, { found: false, edges: [], listed: [], invalid: [] });
});

test('syntax errors carry their line numbers', () => {
    const md = '# G1\n## 순서\n- A -> B\nA -> C\n- A -> B -> C\n- A -> B:3-1\n- A, -> B\n\n## 다음\nfree text\n';
    const r = parseOrder(md);
    assert.equal(r.found, true);
    assert.deepEqual(r.invalid.map((e) => e.line), [4, 5, 6, 7]);
    assert.deepEqual(r.edges.map((e) => [e.from.ref, e.to.ref, e.line]), [['A', 'B', 3]]);
    // T52 (D18): each error names its line as written and the forms the section takes
    assert.deepEqual(r.invalid[0], { line: 4, text: 'A -> C', reason: 'expected "- before -> after" or "- T1, T2"', formats: ORDER_FORMATS });
    assert.deepEqual(ORDER_FORMATS, ['- T1 -> T2', '- T1, T2', '- T1:4-7 -> T2:1']);
    // R50 L1: a line written as a format reads, never refused again
    for (const f of ORDER_FORMATS) assert.deepEqual(parseOrder(`## 순서\n${f}\n`).invalid, [], f);
    assert.ok(r.invalid.every((e) => e.formats === ORDER_FORMATS));
});

test('T52: the goal template has an order section that reads as errors until its placeholders are filled', () => {
    assert.match(GOAL_TEMPLATE, /^# G<n> <title>\n/);
    const r = parseOrder(GOAL_TEMPLATE);
    assert.equal(r.found, true);
    assert.deepEqual([r.edges, r.listed], [[], []]);
    assert.equal(r.invalid.length, 2);
    // filled in, it is an order
    const filled = GOAL_TEMPLATE.replace('<before> -> <after>', 'T1 -> T2').replace('<task>, <task>', 'T3, T4');
    assert.deepEqual(parseOrder(filled).invalid, []);
    assert.deepEqual(refsOf(filled), [['T1', 'T3', 'T4'], ['T2']]);
});

test('an item of a cancelled task does not count as complete', () => {
    const graph = waves(parseOrder(order('A:1 -> B')).edges).waves;
    const r = annotate(graph, [task('A', 'cancelled', [1]), task('B', 'ready')]);
    assert.equal(nodeOf(r, 'B').status, 'waiting');
    assert.deepEqual(nodeOf(r, 'B').blocked_by, [{ ref: 'A:1', state: 'cancelled' }]);
});

test('one item written as a range is the same node', () => {
    assert.deepEqual(refsOf(order('A -> B:4', 'C -> B:4-4')), [['A', 'B', 'C'], ['B:4']]);
});

test('item refs leave from the range nodes that cover them, so an item-level deadlock is a cycle (D#9)', () => {
    const cycleOf = (...lines) => waves(parseOrder(order(...lines)).edges).cycle;
    assert.deepEqual(cycleOf('T1:1 -> T2:3', 'T2:3 -> T1:1'), ['T2:3', 'T1:1', 'T2:3']);
    assert.deepEqual(cycleOf('T1:1 -> T1:1'), ['T1:1', 'T1:1']);
    // an item no range covers still leaves from the body: not a deadlock
    assert.equal(cycleOf('T1:1 -> T2:3', 'T2:3 -> T1:2'), null);
    // what follows a range node comes after it
    assert.deepEqual(refsOf(order('A -> T1:4-7', 'T1:5 -> B')), [['A', 'T1'], ['T1:4-7'], ['B']]);
    assert.deepEqual(refsOf(order('A -> T1:4-7', 'T1:3-4 -> B')), [['A', 'T1'], ['T1:4-7'], ['B']]);
});

test('an item number above the limit is a bad range, not an allocation', () => {
    const r = parseOrder('## 순서\n- A -> T1:1-300000000\n- A -> T1:1001\n- A -> T1:1000\n');
    assert.deepEqual(r.invalid.map((e) => e.line), [2, 3]);
    assert.equal(r.edges.length, 1);
});
