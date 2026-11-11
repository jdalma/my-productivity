/**
 * The board section of the AGENTS.md overlay (T63g, rfc/board-design.md §7): only a board team's workers get
 * it; a team without a board gets the overlay it had before, to the byte.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { generateWorkerOverlay } from '../../src/lib/worker-bootstrap.js';

const roster = [
    { name: 'pm', agentType: 'claude', role: 'PM', teamRole: 'orchestrator' },
    { name: 'dev', agentType: 'claude', role: 'dev', teamRole: 'worker' },
];
const overlay = (workerName, workerRole, extra = {}) => generateWorkerOverlay({
    teamName: 'demo', workerName, agentType: 'claude', workerRole, teamRoster: workerRole ? roster : [],
    bootstrapInstructions: 'brief', instructionStateRoot: '/s/demo', ...extra,
});

test('a team without a board: no board section, and board: null renders the same overlay', () => {
    for (const [w, role] of [['pm', 'orchestrator'], ['dev', 'worker'], ['solo', null]]) {
        const plain = overlay(w, role);
        assert.equal(overlay(w, role, { board: null }), plain);
        assert.doesNotMatch(plain, /board-|Team Board/);
    }
});

test('a worker of a board team: inbox on a [board] notice, take, land instead of a status message, act on changes at once', () => {
    const text = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(text, /## Team Board/);
    assert.match(text, /\[board\][^\n]*board-inbox/);
    assert.match(text, /board-take/);
    assert.match(text, /board-land/);
    assert.match(text, /not in a message body|never in a message body/i);
    assert.match(text, /changes[^\n]*without waiting/i);
    assert.match(text, /send-message/, 'questions and decisions still go by message');
    assert.match(text, /board-review-queue[\s\S]*board-verdict/, 'any worker may be a task\'s reviewer');
    assert.match(text, /code, severity and a repro command/);
    assert.doesNotMatch(text, /board-add/, 'adding tasks is pm\'s');
    assert.match(text, /"team_name\\":\\"demo\\"/, 'commands are written out for this team');
    assert.match(text, /without "since"/, 'R71 R3: a lost cursor');
    // R71 R1: the reviewer's rules after a verdict
    assert.match(text, /Do not send pm or the assignee a message about a verdict/);
    assert.match(text, /assigned to you or that you landed[^\n]*send-message/);
    assert.match(text, /open must finding/);
    assert.match(text, /left_out[^\n]*next_verdict/);
    assert.match(text, /"reopen"/);
});

test('no example in the board section nests double quotes inside its double-quoted --input (R71 L1)', () => {
    for (const [w, role] of [['pm', 'orchestrator'], ['dev', 'worker']]) {
        const text = overlay(w, role, { board: { store: 'sqlite' } });
        for (const cmd of text.match(/--input "(?:[^"\\]|\\.)*"/g) ?? []) assert.doesNotMatch(cmd, /\\\\"/, cmd);
        assert.doesNotMatch(text, /\\"없음\\"/);
    }
});

test('an orchestrator of a board team: tasks through board-add, no relaying, decisions as announcements, recovery from board-status', () => {
    const text = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    for (const re of [/board-add/, /ticket[^\n]*constraints[^\n]*base[^\n]*reviewer/, /없음/, /Do not relay review requests or fix requests/,
        /never the same worker/, /assign yourself[^\n]*reviewer/,
        /board-announce/, /board-finding[^\n]*backlog/, /board-status/]) {
        assert.match(text, re);
    }
});

test('a team that declares no roles: every worker gets the orchestrator part too (everyone is pm there)', () => {
    const text = overlay('solo', null, { board: { store: 'sqlite' } });
    assert.match(text, /board-add/);
    assert.match(text, /board-take/);
});
