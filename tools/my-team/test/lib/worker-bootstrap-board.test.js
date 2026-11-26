/**
 * The board section of the AGENTS.md overlay (T63g; docs/board.md, Turning it on): only a board team's workers get
 * it; a team without a board gets the overlay it had before, to the byte.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

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

test('a worker of a board team: inbox on a board notice (kind board), take, land instead of a status message, act on changes at once', () => {
    const text = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(text, /## Team Board/);
    assert.match(text, /A message of kind `board` is a notice[^\n]*board-inbox/);
    assert.match(text, /board-take/);
    assert.match(text, /board-land/);
    assert.match(text, /not in a message body|never in a message body/i);
    assert.match(text, /changes[^\n]*without waiting/i);
    assert.match(text, /send-message/, 'questions and decisions still go by message');
    assert.match(text, /board-review-queue[\s\S]*board-verdict/, 'any worker may be a task\'s reviewer');
    assert.match(text, /code, severity and a repro command/);
    // B9 (T55): the reviewer's procedure is read when reviewing, in the my-team skill
    assert.match(text, /Before you judge a landing, read "Reviewing a landing" in the `my-team` skill[^\n]*`review-copy`[^\n]*never in a working tree/);
    assert.doesNotMatch(text, /mktemp|git archive/);
    assert.doesNotMatch(text, /board-add/, 'adding tasks is pm\'s');
    // T43 (D15, D16): how to run a command is said once; team_name and the worker come from MY_TEAM_WORKER
    assert.match(text, /Run a command as `my-team api <command> --input '<json>' --json`[^\n]*Leave team_name and yourself[^\n]*MY_TEAM_WORKER gives them[^\n]*--help` lists every field/);
    assert.doesNotMatch(text, /"team_name\\?":\\?"demo/, 'no command repeats the team');
    assert.match(text, /without "since"/, 'R71 R3: a lost cursor');
    // R71 R1: the reviewer's rules after a verdict
    // A4 (T55): what the board tells whom is said once, for every role
    assert.match(text, /\nThe board tells whom it concerns: a land the reviewer[^\n]*a verdict the assignee and pm\. Do not relay review requests or fix requests, nor send a message about a verdict\./);
    assert.match(text, /assigned to you or that you landed[^\n]*send-message/);
    // C11 (T55): the refusal says how to settle an open must finding (service.test.js)
    assert.doesNotMatch(text, /open must finding/);
    assert.match(text, /left_out[^\n]*next_verdict/);
    assert.match(text, /"reopen"/);
    // R71a L1, L2
    assert.match(text, /incomplete[^\n]*send-message[^\n]*missing/);
    assert.match(text, /`hold`[^\n]*cannot verify[^\n]*not `changes`/);
});

test('every --input example is one single-quoted JSON a shell passes as is (R71 L1, T43)', () => {
    for (const [w, role] of [['pm', 'orchestrator'], ['dev', 'worker']]) {
        const text = overlay(w, role, { board: { store: 'sqlite' } });
        const inputs = [...text.matchAll(/--input '([^'\n]*)'/g)].map((m) => m[1]);
        assert.ok(inputs.length >= 5, 'the mailbox and send-message examples');
        // '<json>' and '…' stand for an input, they are not one
        for (const input of inputs) if (input !== '<json>' && input !== '…') assert.doesNotThrow(() => JSON.parse(input), input);
        assert.doesNotMatch(text, /--input "/, 'no double-quoted input to escape');
        assert.doesNotMatch(text, /\\"없음\\"/);
    }
});

test('an orchestrator of a board team: tasks through board-add, no relaying, decisions as announcements, recovery from board-status', () => {
    const text = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    for (const re of [/board-add/, /ticket[^\n]*constraints[^\n]*base[^\n]*reviewer/, /없음/, /Do not relay review requests or fix requests/,
        /board-announce/, /board-finding[^\n]*backlog/, /board-status/]) {
        assert.match(text, re);
    }
    // C10 (T55): board-add and board-land refuse a task its assignee would judge, and say how (service.test.js)
    assert.doesNotMatch(text, /never the same worker/);
    assert.equal(text.match(/Do not relay review requests/g).length, 1, 'A4: once');
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
    assert.match(pm, /at most a question when it is blocked; the rest reaches you on the board/);
    assert.match(pm, /Delegate in ticket form: a ticket file \(what it holds: Spawn protocol, Rules\)/, 'A1: the ticket file is described in the Spawn protocol');
    assert.equal(pm.match(/expected deliverable/g).length, 1, 'A1: once');
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
    }
    // T42 B8: a worker asks pm to move its tasks; pm, and every worker of a team without roles, moves them itself
    assert.match(dev, /Succession[^\n]*ask pm to board-assign them to the successor before it removes you/);
    for (const text of [pm, peer]) assert.match(text, /Succession[^\n]*board-assign them to the successor yourself before it removes you/);
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
    assert.equal(pm.match(/not on the board yet/g).length, 1, 'pm reads the worker rule; T229 dropped its copy');
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
    assert.match(pm, /Correct any open decision[^\n]*the same way \(board-decision-edit, As a worker\), instead of withdrawing it and asking again[^\n]*An answered decision is not edited/);
    assert.equal(pm.match(/`board-decision-edit` \(/g).length, 1, 'A5: the command and its fields once');
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
    assert.match(pm, /board-edit, never in board\.db[^\n]*`board-edit` \(id, constraints\)[^\n]*until it has landed a commit/);
    assert.match(pm, /deliverable changes only while the task is new, ready, doing or changes/);
});

test('T159: every worker is told not to run another my-team version on a running board, and how to try it on a copy', () => {
    for (const role of ['worker', 'orchestrator']) {
        const text = overlay('dev', role, { board: { store: 'sqlite' } });
        assert.match(text, /Never run a my-team of another version[^\n]*running team's board[^\n]*MY_TEAM_STATE_ROOT_BASE[^\n]*AND change `state_root`[^\n]*and `session_name`/);
        // A6, D17 (T55): a migrating write is refused while the team runs (read-no-migrate.test.js); said once
        assert.equal(text.match(/running team's board/g).length, 1);
    }
});

test('pm of a board team: goal files with an order section, ready_now from goal-order with the team filled in', () => {
    const text = overlay('pm', 'orchestrator', { board: { store: 'sqlite' } });
    // D18, C14 (T55): goal-order prints a goal file and lists the line forms; board-add says what a task with no parent needs
    assert.match(text, /goal file `~\/\.my-team\/docs\/demo\/goals\/G<n>-<slug>\.md` \(`goal-order` with `"template":true` prints one\) whose `## 순서` names every task, then add the tasks with `"goal":"G<n>"`/);
    assert.match(text, /no order among them go on one line `- T1, T2`: never invent an order/);
    assert.match(text, /`"single":true` instead of goal/);
    assert.doesNotMatch(text, /board-add refuses it/);
    assert.match(text, /read `ready_now`[^\n]*`goal-order`/);
    assert.match(text, /`cycle` or `errors`[^\n]*`cancelled`[^\n]*rewrite its `## 순서` section/);
    assert.doesNotMatch(text, /<team>/, 'the team name is filled in, not left as a placeholder');
    assert.doesNotMatch(overlay('dev', 'worker', { board: { store: 'sqlite' } }), /goal-order/, 'pm guidance only');
});

test('T226: every render forbids creating tmux panes or sessions; a board team\'s mailbox says how to read reply_to and kind', () => {
    const board = { store: 'sqlite' };
    const renders = {
        'orchestrator+board': overlay('pm', 'orchestrator', { board }),
        'worker+board': overlay('dev', 'worker', { board }),
        'solo dev': overlay('pm', 'orchestrator', { board, solo: true }),
    };
    for (const [w, role] of [['pm', 'orchestrator'], ['dev', 'worker'], ['solo', null]]) renders[`${w} no board`] = overlay(w, role);
    for (const [name, text] of Object.entries(renders)) {
        assert.match(text, /Never create tmux panes or sessions, not even with a tmux the shim does not cover/, name);
    }
    for (const name of ['orchestrator+board', 'worker+board', 'solo dev']) {
        const mailbox = renders[name].split('### Mailbox: questions and notices only')[1].split('## Rules')[0];
        assert.match(mailbox, /"direction: out" is a message you sent, "in" one you received/, name);
        assert.match(mailbox, /no hit, say so\s+in this pane/, name);
        assert.match(mailbox, /Answer a question, closeout or team-handoff with kind `answer` and `reply_to`/, name);
        assert.match(mailbox, /`blocked` \(a task you cannot go on with:\s+`task`, `need`, and the `board_error` a refused board command prints\)/, name);
        assert.doesNotMatch(renders[name], /expects_reply|\[board\]|\[closeout\]/, name);
    }
});

test('T55: a land names its unchecked parts and the check as data; the reviewer procedure lives in the my-team skill', () => {
    const dev = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(dev, /`board-land` \([^)]*check \{cmd, result, counts, failures, excused\}[^)]*unverified\)/);
    assert.match(dev, /`board-verdict` \([^)]*rerun \{cmd, result, counts, failures, excused\}/);
    const skill = readFileSync(new URL('../../../../plugins/workflow/skills/my-team/SKILL.md', import.meta.url), 'utf-8');
    const section = skill.split('### Reviewing a landing')[1]?.split('\n## ')[0] ?? '';
    for (const re of [/sub-agent를 동시에/, /직접 돌린다/, /review-copy/, /working tree에서는 돌리지 않는다/, /`excused`/, /board 사본/, /brief에 그대로/]) assert.match(section, re);
});

test('E21 (T55, D#25): in a board team a blocked task waits on the board; status.json blocked is for a block no task explains', () => {
    const dev = overlay('dev', 'worker', { board: { store: 'sqlite' } });
    assert.match(dev, /## Liveness[\s\S]*A task you cannot go on with waits on the board \(board-wait\)[\s\S]*only for a block no task explains/);
    assert.match(overlay('dev', 'worker'), /When blocked, write \{"state": "blocked"/, 'a team without a board keeps its one channel');
});

test('T46, T47 (R44 L1, R46 S1): every overlay says how to write a quote inside a single-quoted --input, by closing and reopening the quote only', () => {
    const board = { board: { store: 'sqlite' } };
    for (const text of [overlay('pm', 'orchestrator', board), overlay('dev', 'worker', board), overlay('solo', null, board),
        overlay('pm', 'orchestrator'), overlay('dev', 'worker'), overlay('solo', null)]) {
        assert.match(text, /--input '[^\n]*single-quoted[^\n]*as `'\\''`\./);
        assert.doesNotMatch(text, /\\u0027/, 'R46 S1: an escape a tool layer may turn into a quote');
    }
});
