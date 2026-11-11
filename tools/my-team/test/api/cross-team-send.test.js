/**
 * Cross-team send-message tests (`to_team`).
 *
 * The regression these guard against: TeamPaths.root() reads MY_TEAM_STATE_ROOT
 * ahead of its teamName argument, and every worker process has that var pinned
 * to its own team. Composing the recipient's spool path through TeamPaths would
 * therefore write into the SENDER's directory and still report success. Each
 * test below sets MY_TEAM_STATE_ROOT to the sender's root before calling, so a
 * regression to TeamPaths-based addressing fails here instead of in production.
 *
 * tmux is stubbed: resolvePaneBySessionWorker is the only tmux dependency, and
 * these tests care about spool/archive/event placement, not pane delivery.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiSendMessage } from '../../src/commands/api/send-message.js';

/** Build two independent teams under one sessions base, like a real machine. */
function setupTwoTeams() {
    const base = mkdtempSync(join(tmpdir(), 'my-team-xteam-'));

    function mkTeam(teamName, sessionName, workers) {
        const stateRoot = join(base, teamName);
        mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
        const manifest = {
            team_name: teamName,
            state_root: stateRoot,
            session_name: `${sessionName}:0`,
            workers: workers.map((name, i) => ({ name, pane_id: `%${i + 1}` })),
        };
        writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');
        return { teamName, sessionName, stateRoot };
    }

    const teamA = mkTeam('team-a', 'my-team-team-a-aaa111', ['alice', 'shared']);
    const teamB = mkTeam('team-b', 'my-team-team-b-bbb222', ['bob', 'shared']);

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    // Simulate a worker process in team A: its env is pinned to its OWN root.
    process.env.MY_TEAM_STATE_ROOT = teamA.stateRoot;

    return { base, teamA, teamB };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    delete process.env.MY_TEAM_STATE_ROOT;
    rmSync(ctx.base, { recursive: true, force: true });
}

function readSpool(stateRoot, worker) {
    const dir = join(stateRoot, 'incoming-spool', worker);
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter((n) => n.endsWith('.json'))
        .map((n) => JSON.parse(readFileSync(join(dir, n), 'utf-8')));
}

function readEvents(stateRoot) {
    const f = join(stateRoot, 'events.jsonl');
    if (!existsSync(f)) return [];
    // message lines only: these fixtures have no live pane, so each send also logs a trigger-refused line (T63e2)
    return readFileSync(f, 'utf-8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l)).filter((e) => e.type === 'message');
}

/** Injected tmux seam (same pattern as add-worker tests): pane resolves to %99. */
function paneDeps(impl) {
    return { resolvePaneBySessionWorker: impl ?? (async () => '%99') };
}

test('cross-team send lands in the RECIPIENT team spool, not the sender root', async () => {
    const ctx = setupTwoTeams();
    try {
        const result = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'alice',
            to_team: 'team-b', to_worker: 'bob',
            body: 'cross-team hello',
        }, paneDeps());
        assert.equal(result.ok, true);
        assert.equal(result.delivered_to_team, 'team-b');
        assert.equal(result.delivered_to_session, undefined, 'session names are no longer part of the contract');

        const bSpool = readSpool(ctx.teamB.stateRoot, 'bob');
        assert.equal(bSpool.length, 1, 'message must land in team-b spool');
        assert.equal(bSpool[0].body, 'cross-team hello');

        // The env-pollution regression: nothing may be written under team-a.
        assert.equal(readSpool(ctx.teamA.stateRoot, 'bob').length, 0,
            'must NOT write the recipient spool under the sender state root');
    } finally {
        cleanup(ctx);
    }
});

test('cross-team message carries from_team so the recipient can reply back', async () => {
    const ctx = setupTwoTeams();
    try {
        await runApiSendMessage({
            team_name: 'team-a', from_worker: 'alice',
            to_team: 'team-b', to_worker: 'bob',
            body: 'need an answer', expects_reply: true,
        }, paneDeps());
        const [msg] = readSpool(ctx.teamB.stateRoot, 'bob');
        assert.equal(msg.from_team, 'team-a', 'without from_team the recipient cannot address a reply back');
        assert.equal(msg.from_session, undefined, 'session names are no longer carried');
        assert.equal(msg.expects_reply, true);
    } finally {
        cleanup(ctx);
    }
});

test('cross-team send mirrors the event into BOTH team logs', async () => {
    const ctx = setupTwoTeams();
    try {
        const r = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'alice',
            to_team: 'team-b', to_worker: 'bob', body: 'ping',
        }, paneDeps());
        const aEvents = readEvents(ctx.teamA.stateRoot);
        const bEvents = readEvents(ctx.teamB.stateRoot);
        assert.equal(aEvents.length, 1);
        assert.equal(bEvents.length, 1, 'recipient monitor must see the message too');
        assert.equal(aEvents[0].message_id, r.message_id);
        assert.equal(aEvents[0].to_team, 'team-b');
        assert.equal(aEvents[0].to_session, undefined);
        assert.equal(bEvents[0].message_id, r.message_id);
        assert.equal(bEvents[0].from_team, 'team-a');
    } finally {
        cleanup(ctx);
    }
});

test('same-name worker in another team is a distinct peer (expects_reply allowed)', async () => {
    const ctx = setupTwoTeams();
    try {
        // Both teams have a worker literally named "shared". Cross-team, this is
        // not a self-message, so the self-reply guard must not fire.
        const r = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'shared',
            to_team: 'team-b', to_worker: 'shared',
            body: 'question for my namesake', expects_reply: true,
        }, paneDeps());
        assert.equal(r.expects_reply, true);
        assert.equal(readSpool(ctx.teamB.stateRoot, 'shared').length, 1);
    } finally {
        cleanup(ctx);
    }
});

test('cross-team send rejects a worker missing from the target team', async () => {
    const ctx = setupTwoTeams();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-a', from_worker: 'alice',
                to_team: 'team-b', to_worker: 'ghost', body: 'hi',
            }, paneDeps()),
            /not in team 'team-b'/
        );
    } finally {
        cleanup(ctx);
    }
});

test('the removed to_session field is rejected, not silently treated as same-team', async () => {
    const ctx = setupTwoTeams();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-a', from_worker: 'alice',
                to_session: ctx.teamB.sessionName, to_worker: 'shared', body: 'hi',
            }, paneDeps()),
            /to_session.*removed.*to_team/
        );
        assert.equal(readSpool(ctx.teamA.stateRoot, 'shared').length, 0,
            'a legacy to_session send must not be delivered to the same-name worker in the sender team');
    } finally {
        cleanup(ctx);
    }
});

test('a dead tmux session fails the send (no silent unread spool)', async () => {
    const ctx = setupTwoTeams();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-a', from_worker: 'alice',
                to_team: 'team-b', to_worker: 'bob', body: 'hi',
            }, paneDeps(async () => { throw new Error("tmux session 'x' not found or has no panes."); })),
            /not found or has no panes/
        );
        assert.equal(readSpool(ctx.teamB.stateRoot, 'bob').length, 0,
            'nothing may be spooled when the recipient session is dead');
    } finally {
        cleanup(ctx);
    }
});

test('same-team send is unchanged when to_team is omitted', async () => {
    const ctx = setupTwoTeams();
    try {
        const r = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'alice', to_worker: 'shared', body: 'local',
        }, paneDeps());
        assert.equal(r.delivered_to, 'shared');
        assert.equal(r.delivered_to_team, undefined, 'same-team result must carry no cross-team fields');
        assert.equal(readSpool(ctx.teamA.stateRoot, 'shared').length, 1);
        assert.equal(readSpool(ctx.teamB.stateRoot, 'shared').length, 0);
        const [msg] = readSpool(ctx.teamA.stateRoot, 'shared');
        assert.equal(msg.from_team, undefined, 'same-team messages carry no team metadata');
    } finally {
        cleanup(ctx);
    }
});
