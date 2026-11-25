/**
 * Role-aware AGENTS.md overlay tests.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { generateWorkerOverlay } from '../../src/lib/worker-bootstrap.js';

const roster = [
    { name: 'pm', agentType: 'claude', role: 'PM hub', teamRole: 'orchestrator' },
    { name: 'dev', agentType: 'claude', role: 'backend dev', teamRole: 'worker' },
];

function overlayFor(workerName, workerRole) {
    return generateWorkerOverlay({
        teamName: 'demo', workerName, agentType: 'claude',
        workerRole, teamRoster: roster, bootstrapInstructions: '', instructionStateRoot: '/s/demo',
    });
}

test('T100: only the orchestrator is told to spread work, split tickets, leave merges to each worker and add a worker only for a ticket that can run in parallel', () => {
    const rules = [/Spread the work[^\n]*split the ticket along file boundaries or give it to the idle worker/,
        /working tree, so nothing needs merging" is not a reason/, /is several tickets: split it/,
        /No worker is the team's merger[^\n]*merges the target branch into its own branch/, /no other worker is free, decide whether it can run in parallel[^\n]*other files[^\n]*no result of a ticket still in progress[^\n]*expensive to undo[^\n]*review is not already behind[^\n]*without asking the user first[^\n]*leave the ticket queued/];
    const pm = overlayFor('pm', 'orchestrator');
    const dev = overlayFor('dev', 'worker');
    for (const re of rules) { assert.match(pm, re); assert.doesNotMatch(dev, re); }
});

test('Liveness asks for the status file my-team status reads, and for no heartbeat file, which nothing reads', () => {
    for (const [name, role] of [['pm', 'orchestrator'], ['dev', 'worker'], ['solo', null]]) {
        const text = overlayFor(name, role);
        assert.match(text, new RegExp(`## Liveness\\n- \\*\\*Status\\*\\*: Write to [^\\n]*workers/${name}/status\\.json`));
        assert.doesNotMatch(text, /heartbeat/i);
    }
});

test('orchestrator overlay carries the delegation discipline and cross-team gateway duty', () => {
    const text = overlayFor('pm', 'orchestrator');
    assert.match(text, /## Team Role: ORCHESTRATOR/);
    assert.match(text, /ticket form/);
    assert.match(text, /sent_pending/);
    assert.match(text, /RFC file/);
    assert.doesNotMatch(text, /every worker \(including you\) is a peer/);
});

test('orchestrator overlay carries the cross-team Q&A quality rules', () => {
    const text = overlayFor('pm', 'orchestrator');
    assert.match(text, /read its published docs/, 'docs-first rule');
    assert.match(text, /Answers must cite evidence/, 'evidence citation rule');
    assert.match(text, /never replace the original with your summary/, 'no lossy relay rule');
    assert.match(text, /FAQ\/decisions log/, 'Q&A accumulation rule');
});

test('worker overlay carries the evidence discipline', () => {
    const text = overlayFor('dev', 'worker');
    assert.match(text, /must cite file:line/);
});

test('worker overlay names its orchestrators and blocks cross-team', () => {
    const text = overlayFor('dev', 'worker');
    assert.match(text, /## Team Role: WORKER/);
    assert.match(text, /\(pm\)/, 'must name the orchestrator(s)');
    assert.match(text, /Cross-team messaging is blocked/);
});

test('roster marks orchestrators', () => {
    const text = overlayFor('dev', 'worker');
    assert.match(text, /\*\*pm\*\* \[claude\] \[ORCHESTRATOR\]/);
    assert.doesNotMatch(text, /\*\*dev\*\*.*\[ORCHESTRATOR\]/);
});

test('legacy overlay (no role) keeps the peer-symmetric text and no role section', () => {
    const text = generateWorkerOverlay({
        teamName: 'demo', workerName: 'a', agentType: 'claude',
        teamRoster: [{ name: 'a', agentType: 'claude', role: '' }],
        bootstrapInstructions: '', instructionStateRoot: '/s/demo',
    });
    assert.match(text, /every worker \(including you\) is a peer/);
    assert.doesNotMatch(text, /## Team Role:/);
});

test('cross-team section documents to_team addressing', () => {
    const text = overlayFor('pm', 'orchestrator');
    assert.match(text, /to_team\\{0,2}":\\{0,2}"<team-name>/);
    assert.match(text, /Prefer `to_team`/);
});

test('overlay carries no dead protocol: no shutdown-ack ritual, no to_session addressing', () => {
    for (const text of [overlayFor('pm', 'orchestrator'), overlayFor('dev', 'worker')]) {
        assert.doesNotMatch(text, /Shutdown Protocol/);
        assert.doesNotMatch(text, /shutdown-ack/);
        assert.doesNotMatch(text, /to_session/);
        assert.doesNotMatch(text, /from_session/);
    }
});

test('overlay tells workers the roster is a boot snapshot refreshed by mailbox-list, and how to read another team', () => {
    const text = overlayFor('pm', 'orchestrator');
    assert.match(text, /mailbox-list.*roster|roster.*mailbox-list/s, 'live roster arrives with every mailbox-list');
    assert.match(text, /api roster/, 'cross-team roster lookup command');
});

test('worker overlay allows same-team peer initiation and explains add-worker --worktree for parallel work', () => {
    for (const text of [overlayFor('dev', 'worker'), overlayFor('pm', 'orchestrator')]) {
        assert.doesNotMatch(text, /do NOT initiate conversations/);
        assert.doesNotMatch(text, /may only initiate messages to an orchestrator/);
        assert.match(text, /add-worker[^\n]*--worktree/, 'any worker may add a worktree peer');
        assert.match(text, /\.worktrees\//, 'documents where the worktree lands');
    }
});
// ── File overlap is NOT policed: worktrees + git merge handle it ──

test('orchestrator overlay narrates team changes to the user without policing file overlap', () => {
    const text = overlayFor('pm', 'orchestrator');
    assert.match(text, /report-in message/, 'a mid-session joiner reports in to it');
    assert.match(text, /never fan the same notice out to every worker/,
        'join/departure narration goes to the user, not the whole team');
    assert.match(text, /Do not police file overlap between workers/,
        'overlap is left to worktrees + git merge');
    assert.doesNotMatch(text, /Work map/, 'no file-ownership map to maintain');
    assert.doesNotMatch(text, /files\/dirs that ticket touches/, 'no file scope tracking');
});

test('worker overlay leaves file coordination to worktrees instead of peer polling', () => {
    const text = overlayFor('dev', 'worker');
    assert.match(text, /Do NOT poll peers to ask what they are editing/);
    assert.match(text, /separate git worktrees/, 'the reason is worktree isolation');
    assert.match(text, /Do NOT introduce yourself to peers when you join/,
        'no greeting fan-out on join');
    assert.match(text, /Seeing a peer here is NOT a reason to message it/,
        'the roster section agrees with the role section');
});

test('a spawning worker registers the new peer with the orchestrator, without file scope', () => {
    const text = overlayFor('dev', 'worker');
    assert.match(text, /Tell the orchestrator \(pm\)[^\n]*spawned this peer/,
        'the team picture of who is working stays complete');
    assert.doesNotMatch(text, /the files it will touch/, 'file scope is not registered');
});

test('the worktree recipe does not ask peers to coordinate file edits', () => {
    for (const text of [overlayFor('dev', 'worker'), overlayFor('pm', 'orchestrator')]) {
        assert.doesNotMatch(text, /ask each other before touching the same files/,
            'worktrees remove the need for that handshake');
        assert.match(text, /git resolves the rest at merge time/);
    }
});

test('a roleless peer team keeps the old peer-initiation wording', () => {
    const text = generateWorkerOverlay({
        teamName: 'demo', workerName: 'solo', agentType: 'claude',
        workerRole: null, teamRoster: [], bootstrapInstructions: '', instructionStateRoot: '/s/demo',
    });
    assert.match(text, /send that peer a message instead of solving it/);
    assert.doesNotMatch(text, /Do not police file overlap/);
});

test('T42 B7: the Spawn protocol tells a worker to tell pm, and never tells pm to tell itself', () => {
    const board = { store: 'sqlite' };
    const line = /Tell the orchestrator \(pm\) in ONE message that you spawned this peer/;
    assert.match(overlayFor('dev', 'worker'), line);
    assert.doesNotMatch(overlayFor('pm', 'orchestrator'), line);
    assert.doesNotMatch(generateWorkerOverlay({
        teamName: 'demo', workerName: 'pm', agentType: 'claude', workerRole: 'orchestrator', teamRoster: roster,
        bootstrapInstructions: '', instructionStateRoot: '/s/demo', board,
    }), line);
});

test('T42 B8: on succession a worker asks pm to move its tasks; pm moves its own with board-assign', () => {
    const render = (workerName, workerRole) => generateWorkerOverlay({
        teamName: 'demo', workerName, agentType: 'claude', workerRole, teamRoster: roster,
        bootstrapInstructions: '', instructionStateRoot: '/s/demo', board: { store: 'sqlite' },
    });
    assert.match(render('dev', 'worker'), /ask pm to board-assign them to the successor/);
    const pm = render('pm', 'orchestrator');
    assert.doesNotMatch(pm, /ask pm to board-assign/);
    assert.match(pm, /\*\*Succession[^\n]*board-assign them to the successor yourself/);
});

test('T42 E20: every board role, solo ones included, is told how to find its tasks again after a compaction', () => {
    const board = { store: 'sqlite' };
    const render = (workerName, workerRole, extra = {}) => generateWorkerOverlay({
        teamName: 'demo', workerName, agentType: 'claude', workerRole, teamRoster: workerRole ? roster : [],
        bootstrapInstructions: '', instructionStateRoot: '/s/demo', board, ...extra,
    });
    for (const text of [render('dev', 'worker'), render('pm', 'orchestrator'), render('solo', null),
        render('pm', 'orchestrator', { solo: true }), render('dev', 'worker', { solo: true })]) {
        const lines = text.split('\n').filter((l) => /compaction/.test(l) && /board-status/.test(l));
        assert.equal(lines.length, 1, 'one recovery line');
        assert.match(lines[0], /board-inbox/);
    }
    assert.doesNotMatch(render('dev', 'worker', { board: undefined }), /After a context compaction/, 'no board, no board recovery');
});
