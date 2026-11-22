/**
 * The board section of the AGENTS.md overlay (T63g; docs/board.md, Turning it on): only a board team's workers get
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
    assert.match(text, /give each review request to one[^\n]*one sub-agent per request at the same time[^\n]*the verdict is yours/);
    assert.match(text, /Every rerun[^\n]*on a copy of the submitted commit in a folder of its own[^\n]*git archive[^\n]*install the dependencies[^\n]*never in a working tree that a worker or another sub-agent uses[^\n]*The copy has no \.git/);
    assert.doesNotMatch(text, /board-add/, 'adding tasks is pm\'s');
    assert.match(text, /"team_name\\":\\"demo\\"/, 'commands are written out for this team');
    assert.match(text, /without "since"/, 'R71 R3: a lost cursor');
    // R71 R1: the reviewer's rules after a verdict
    assert.match(text, /Do not send pm or the assignee a message about a verdict/);
    assert.match(text, /assigned to you or that you landed[^\n]*send-message/);
    assert.match(text, /open must finding/);
    assert.match(text, /left_out[^\n]*next_verdict/);
    assert.match(text, /"reopen"/);
    // R71a L1, L2
    assert.match(text, /incomplete[^\n]*send-message[^\n]*missing/);
    assert.match(text, /`hold`[^\n]*cannot verify[^\n]*not `changes`/);
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

test('a board team hands out, reports and follows work on the board: no line of the role or of the add-worker recipe sends it by message', () => {
    const board = { board: { store: 'sqlite' } };
    const pm = overlay('pm', 'orchestrator', board), dev = overlay('dev', 'worker', board), peer = overlay('solo', null, board);
    const byMessage = [/reply to this message when done/, /one final report/, /hand it a ticket via send-message/, /final report lands in your/, /status file or/, /progress goes to your status file/, /final report to the worker that spawned you/];
    for (const text of [pm, dev, peer]) for (const re of byMessage) assert.doesNotMatch(text, re);
    // without a board every one of those lines is still there, in the overlay of the role that carries it
    const plain = overlay('pm', 'orchestrator') + overlay('dev', 'worker');
    for (const re of byMessage) assert.match(plain, re);
    assert.doesNotMatch(plain, /board-assign them to the successor/);

    assert.match(pm, /Delegate in ticket form[^\n]*put on the board as one task[^\n]*One task = one deliverable/);
    assert.match(pm, /when a task is done the board tells you at its verdict[^\n]*read the task's progress on the board/);
    assert.match(dev, /Message your orchestrator ONLY when you need a decision[^\n]*tells you to tell or ask pm something[^\n]*Do not message when a task is done: board-land records it[^\n]*at the verdict[^\n]*board-progress/);
    assert.match(dev, /in the report you land \(the `report` of board-land\)/);
    assert.match(pm, /Then put its work on the board as a task assigned to it \(board-add, or board-assign to move one\)/);
    assert.match(peer, /Then put its work on the board as a task assigned to it/, 'a team without roles: every worker is pm');
    assert.match(dev, /Then ask pm to put its work on the board as a task assigned to it/);
    for (const text of [pm, dev, peer]) {
        assert.match(text, /MUST say: "Spawned by (pm|dev|solo)\. Your work comes as a board task: start it with board-take and record it with board-land[^\n]*ONLY when you need a decision/);
        assert.match(text, /The ticket = a file[^\n]*given as the task's `ticket`/);
        assert.match(text, /Do not ask the peer for progress; read the task's progress on the board/);
        assert.match(text, /Closeout[^\n]*land your tasks with board-land first and wait for their verdicts[^\n]*Once they are approved[^\n]*names your tasks on the board and their verdicts[^\n]*Never remove yourself/);
        assert.match(text, /Succession[^\n]*ask pm to board-assign them to the successor before it removes you/);
    }
});

test('T100: pm is told to read in_hand before assigning and what the load warning means; a worker is not', () => {
    const pm = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    assert.match(pm, /workers\[\]\.in_hand[^\n]*board-status/);
    assert.match(pm, /`warning`[^\n]*board-add or board-assign[^\n]*went through anyway/);
    assert.match(pm, /no other worker who has taken a task is free[^\n]*decide whether the task can run in parallel[^\n]*names a worker with no task yet[^\n]*board-assign[^\n]*only when there is no such worker[^\n]*If it cannot, leave it/);
    assert.doesNotMatch(overlay('dev', 'worker', { board: { store: 'sqlite' } }), /in_hand|loaded worker/);
});

test('T115: a worker puts a decision only the user can make on the board with a decision brief; pm records the answer', () => {
    const dev = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(dev, /board-wait[^\n]*question[^\n]*context[^\n]*options[^\n]*pros[^\n]*cons[^\n]*recommendation[^\n]*impact[^\n]*refs/);
    assert.match(dev, /decide from it alone/);
    assert.doesNotMatch(dev, /board-answer/);
    const pm = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    assert.match(pm, /board-answer[^\n]*chosen[^\n]*기타/);
});

test('T146: every decision for the user goes on the board first, tied to the task it serves; pm records answers and decisions already made', () => {
    for (const [name, role] of [['dev', 'worker'], ['pm', 'orchestrator']]) {
        const text = overlay(name, role, { board: { store: 'sqlite' } });
        assert.match(text, /Every decision you ask the user goes on the board BEFORE you ask it in your pane, one board entry per decision/);
        assert.match(text, /several are queued, put them all on the board now, even if you ask the user one at a time/);
        assert.match(text, /Tie a decision to the task it serves[^\n]*not on the board yet[^\n]*goes on the board first, without an assignee/);
        assert.match(text, /cannot go on without the answer: put it in waiting[^\n]*board-wait/);
        assert.match(text, /can go on, or it has several decisions open[^\n]*board-ask[^\n]*tasks/);
        assert.match(text, /Only a decision that serves no task at all goes on with `board-ask` and no `tasks`/);
    }
    const pm = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    assert.match(pm, /work that is not on the board yet[^\n]*add that task first with `board-add`/);
    assert.match(pm, /`decisions\.open`[^\n]*record it at once[^\n]*board-answer[^\n]*D#…[^\n]*철회/);
    assert.match(pm, /made without being asked[^\n]*board-ask[^\n]*answered/);
    assert.match(pm, /`board-announce` is for notices to the team\. It is not where a user decision is recorded/);
    assert.doesNotMatch(pm, /Record user decisions with[^\n]*board-announce/);
});

test('T203: a worker corrects an open decision it asked, and pm any, with board-decision-edit instead of asking again', () => {
    const dev = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(dev, /open decision you asked[^\n]*correct that entry instead of asking a new one[^\n]*board-decision-edit[^\n]*D#… or the waiting task[^\n]*pm is told/);
    assert.doesNotMatch(dev, /instead of withdrawing it/);
    const pm = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    assert.match(pm, /instead of withdrawing it and asking again[^\n]*board-decision-edit[^\n]*only the fields that changed[^\n]*An answered decision is not edited/);
});

test('T127: a worker leaves progress by the ticket\'s item numbers; pm writes numbered items and reads progress', () => {
    const dev = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(dev, /board-progress[^\n]*item[^\n]*note[^\n]*done/);
    assert.match(dev, /finish one of the ticket's numbered items[^\n]*30 minutes[^\n]*stuck/);
    assert.match(dev, /sentences a person can follow, not only a commit hash or a path/);
    assert.doesNotMatch(dev, /numbered list in its What section/);
    const pm = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    assert.match(pm, /numbered list in its What section[^\n]*read its progress on the board/);
});

test('a team that declares no roles: every worker gets the orchestrator part too (everyone is pm there)', () => {
    const text = overlay('solo', null, { board: { store: 'sqlite' } });
    assert.match(text, /board-add/);
    assert.match(text, /board-take/);
});

test('T158: a worker lands a document task without a commit, a reviewer judges it without one, pm marks and edits tasks', () => {
    const dev = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(dev, /document task[^\n]*lands the same way without `commit`[^\n]*ask pm to mark it/);
    assert.match(dev, /document task's landing has no commit[^\n]*leave `verified_commit` out/);
    assert.doesNotMatch(dev, /board-edit/);
    const pm = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    assert.match(pm, /"deliverable":"document"[^\n]*instead of cancelled/);
    assert.match(pm, /board-edit, never in board\.db[^\n]*board-edit --input[^\n]*until it has landed a commit/);
    assert.match(pm, /deliverable changes only while the task is new, ready, doing or changes/);
});

test('T159: every worker is told not to run another my-team version on a running board, and how to try it on a copy', () => {
    for (const role of ['worker', 'orchestrator']) {
        const text = overlay('dev', role, { board: { store: 'sqlite' } });
        assert.match(text, /Never run a my-team of another version[^\n]*running team's board[^\n]*MY_TEAM_STATE_ROOT_BASE[^\n]*AND change `state_root`/);
        assert.match(text, /changes my-team itself is verified on a copy[^\n]*sub-agent/);
    }
});

test('pm of a board team: goal files with an order section, ready_now from goal-order with the team filled in', () => {
    const text = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    assert.match(text, /goal file `~\/\.my-team\/docs\/demo\/goals\/G<n>-<slug>\.md`[^\n]*## 순서[^\n]*- <before> -> <after>/);
    assert.match(text, /first write a goal file[^\n]*names every task, then add the tasks with `"goal":"G<n>"`/);
    assert.match(text, /A task with no `parent`[^\n]*board-add refuses it[^\n]*`"single":true`/);
    assert.match(text, /read `ready_now`[^\n]*team api goal-order --input "\{\\"team_name\\":\\"demo\\"\}" --json/);
    assert.match(text, /`cycle` or `errors`[^\n]*`cancelled`[^\n]*rewrite its `## 순서` section/);
    assert.doesNotMatch(text, /<team>/, 'the team name is filled in, not left as a placeholder');
    assert.doesNotMatch(overlay('dev', 'worker', { board: { store: 'sqlite' } }), /goal-order/, 'pm guidance only');
});
