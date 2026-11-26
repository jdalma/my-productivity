/**
 * Size bound on the rendered AGENTS.md overlay (E7): every worker reads it at boot and again after every context
 * compaction, so each byte here is paid per worker per compaction. Rendered with an empty extra_prompt, so the
 * bound is on what my-team itself adds.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { generateWorkerOverlay } from '../../src/lib/worker-bootstrap.js';

const roster = [
    { name: 'pm', agentType: 'claude', role: 'PM hub', teamRole: 'orchestrator' },
    { name: 'dev', agentType: 'claude', role: 'backend dev', teamRole: 'worker' },
    { name: 'qa', agentType: 'claude', role: 'tests', teamRole: 'worker' },
];
const board = { store: 'sqlite' };
const render = (workerName, workerRole, extra = {}) => Buffer.byteLength(generateWorkerOverlay({
    teamName: 'demo', workerName, agentType: 'claude', workerRole, bootstrapInstructions: '',
    instructionStateRoot: '/Users/someone/.my-team/sessions/demo', teamRoster: workerRole ? roster : [], ...extra,
}));

// [rendered bytes bound, render]. Measured 2026-11-21 before E7: 14.8K, 29.5K, 16.9K, 26.3K, 20.2K, 35.0K, 30.3K, 26.3K.
// orchestrator+board stays near 30K: the board's worker, reviewer and pm rules are each pinned by a test of their own.
// T221/T222 added the goal declaration to board-add (orchestrator+board 30,070, solo dev 22,019), so both bounds rose by 500.
// T229 cut four sentences that repeated another (peer+board 24,973 -> 24,299) and raised peer+board by 400, so the next
// rule fits with 1,000 bytes to spare: what is left there says one thing once.
// T43 wrote each command as its name and input fields, without team_name and escaped JSON, and the decision fields once
// (pm+board 29,607 -> 27,645, dev+board 19,610 -> 18,581): each bound is now the next 500 above its size with 150 to spare.
// T55 moved what a tool now says or refuses out of the text, the reviewer's procedure into the my-team skill, and said
// repeated rules once (pm+board 27,872 -> 25,391, dev+board 18,780 -> 17,250): each bound went down by what its render lost.
const COMBOS = {
    peer: [12_029, () => render('solo', null)],
    'peer+board': [20_731, () => render('solo', null, { board })],
    worker: [13_029, () => render('dev', 'worker')],
    'worker+board': [17_470, () => render('dev', 'worker', { board })],
    orchestrator: [17_529, () => render('pm', 'orchestrator')],
    'orchestrator+board': [25_519, () => render('pm', 'orchestrator', { board })],
    'solo dev': [19_023, () => render('pm', 'orchestrator', { board, solo: true })],
    'solo reviewer': [17_470, () => render('dev', 'worker', { board, solo: true })],
};

test('E7: the overlay of each role and board combination stays under its size bound', () => {
    for (const [name, [bound, size]] of Object.entries(COMBOS)) assert.ok(size() <= bound, `${name}: ${size()} bytes > ${bound}`);
});

test('E7: each overlay keeps only the sections its worker can act on', () => {
    const text = (workerName, workerRole, extra = {}) => generateWorkerOverlay({
        teamName: 'demo', workerName, agentType: 'claude', workerRole, bootstrapInstructions: '',
        instructionStateRoot: '/s/demo', teamRoster: roster, ...extra,
    });
    assert.doesNotMatch(text('dev', 'worker'), /to_team/, 'a role-team worker can neither send nor receive cross-team');
    assert.match(text('pm', 'orchestrator'), /to_team/);
    assert.doesNotMatch(text('pm', 'orchestrator', { board, solo: true }), /As a reviewer/, 'the solo dev is never a task\'s reviewer');
    assert.match(text('pm', 'orchestrator', { board }), /As a reviewer/);
    const boardDev = text('dev', 'worker', { board });
    assert.match(boardDev, /### Mailbox: questions and notices only[\s\S]*best-effort hint[\s\S]*archive-lookup/);
    assert.doesNotMatch(boardDev, /reply_to resolution order/);
    assert.match(text('dev', 'worker'), /reply_to resolution order/, 'a team without a board keeps the full protocol');
    assert.match(text('dev', 'worker'), /Before any risky command, ask the user in this pane/, 'the claude guidance keeps its risky-command rule');
    for (const t of [text('dev', 'worker'), boardDev]) assert.match(t, /Never type into another worker's pane/);
});
