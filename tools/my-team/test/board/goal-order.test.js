/**
 * Goal order (T210; plan research/my-team-goal-order-plan.md 2.1-2.3, cases of section 4).
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { annotate, parseOrder, waves } from '../../src/board/core/goal-order.js';

const order = (...lines) => `# G1 goal\n\n## 순서\n${lines.map((l) => `- ${l}`).join('\n')}\n`;
const refsOf = (md) => waves(parseOrder(md).edges).waves.map((w) => w.map((n) => n.ref));
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
    assert.deepEqual(r, { found: false, edges: [], invalid: [] });
});

test('syntax errors carry their line numbers', () => {
    const md = '# G1\n## 순서\n- A -> B\nA -> C\n- A -> B -> C\n- A -> B:3-1\n- A, -> B\n\n## 다음\nfree text\n';
    const r = parseOrder(md);
    assert.equal(r.found, true);
    assert.deepEqual(r.invalid.map((e) => e.line), [4, 5, 6, 7]);
    assert.deepEqual(r.edges.map((e) => [e.from.ref, e.to.ref, e.line]), [['A', 'B', 3]]);
});
