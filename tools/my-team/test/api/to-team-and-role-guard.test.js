/**
 * `to_team` addressing + orchestrator/worker role guard tests.
 *
 * Fixture: two teams under one sessions base.
 *   team-a (roles): orchestrator 'pm-a', workers 'dev-a', 'aux-a'
 *   team-b (roles): orchestrator 'pm-b', worker  'dev-b'
 *   team-c (legacy, no roles): 'carol', 'dan'
 *
 * tmux is stubbed via the resolvePaneBySessionWorker seam, same as
 * cross-team-send.test.js — these tests care about routing decisions and
 * spool placement, not pane delivery.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiSendMessage } from '../../src/commands/api/send-message.js';

function setup() {
    const base = mkdtempSync(join(tmpdir(), 'my-team-roleguard-'));

    function mkTeam(teamName, sessionName, workers) {
        const stateRoot = join(base, teamName);
        mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
        const manifest = {
            team_name: teamName,
            state_root: stateRoot,
            session_name: `${sessionName}:0`,
            workers: workers.map((w, i) => ({ pane_id: `%${i + 1}`, ...w })),
        };
        writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');
        return { teamName, sessionName, stateRoot };
    }

    const teamA = mkTeam('team-a', 'my-team-team-a-aaa111', [
        { name: 'pm-a', role: 'orchestrator' },
        { name: 'dev-a', role: 'worker' },
        { name: 'aux-a', role: 'worker' },
    ]);
    const teamB = mkTeam('team-b', 'my-team-team-b-bbb222', [
        { name: 'pm-b', role: 'orchestrator' },
        { name: 'dev-b', role: 'worker' },
    ]);
    const teamC = mkTeam('team-c', 'my-team-team-c-ccc333', [
        { name: 'carol' },
        { name: 'dan' },
    ]);

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    process.env.MY_TEAM_STATE_ROOT = teamA.stateRoot;
    return { base, teamA, teamB, teamC };
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

const paneDeps = { resolvePaneBySessionWorker: async () => '%99' };

// ── to_team addressing ──

test('to_team delivers into the target team spool by TEAM NAME (no session name needed)', async () => {
    const ctx = setup();
    try {
        const r = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'pm-a',
            to_team: 'team-b', to_worker: 'pm-b', body: 'hello by name',
        }, paneDeps);
        assert.equal(r.ok, true);
        assert.equal(r.delivered_to_team, 'team-b');
        const spool = readSpool(ctx.teamB.stateRoot, 'pm-b');
        assert.equal(spool.length, 1);
        assert.equal(spool[0].from_team, 'team-a');
        assert.equal(spool[0].from_session, undefined, 'session names are no longer carried');
    } finally {
        cleanup(ctx);
    }
});

test('to_team rejects an unknown team with a clear error', async () => {
    const ctx = setup();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-a', from_worker: 'pm-a',
                to_team: 'team-nope', to_worker: 'ghost', body: 'hi',
            }, paneDeps),
            /Team 'team-nope' manifest not found/
        );
    } finally {
        cleanup(ctx);
    }
});

test('to_team with a dead tmux session fails the send (liveness stays tmux-authoritative)', async () => {
    const ctx = setup();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-a', from_worker: 'pm-a',
                to_team: 'team-b', to_worker: 'pm-b', body: 'hi',
            }, { resolvePaneBySessionWorker: async () => { throw new Error('tmux session not found or has no panes.'); } }),
            /not found or has no panes/
        );
        assert.equal(readSpool(ctx.teamB.stateRoot, 'pm-b').length, 0);
    } finally {
        cleanup(ctx);
    }
});

// ── role guard: sender side ──

test('role worker CAN initiate to a sibling worker (same-team peer messaging is open; roles gate cross-team only)', async () => {
    const ctx = setup();
    try {
        const r = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'dev-a', to_worker: 'aux-a', body: 'does your change touch OrderService?',
            expects_reply: true,
        }, paneDeps);
        assert.equal(r.ok, true);
        assert.equal(readSpool(ctx.teamA.stateRoot, 'aux-a').length, 1);
    } finally {
        cleanup(ctx);
    }
});

test('role worker may message its orchestrator, and may REPLY to a sibling', async () => {
    const ctx = setup();
    try {
        const toOrch = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'dev-a', to_worker: 'pm-a',
            body: 'report', expects_reply: true,
        }, paneDeps);
        assert.equal(toOrch.ok, true);

        const reply = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'dev-a', to_worker: 'aux-a',
            body: 'answering your question', reply_to: 'some-earlier-id',
        }, paneDeps);
        assert.equal(reply.ok, true);
        assert.equal(readSpool(ctx.teamA.stateRoot, 'aux-a').length, 1);
    } finally {
        cleanup(ctx);
    }
});

test('role worker self-notification (expects_reply=false) still works', async () => {
    const ctx = setup();
    try {
        const r = await runApiSendMessage({
            team_name: 'team-a', from_worker: 'dev-a', to_worker: 'dev-a', body: 'note to self',
        }, paneDeps);
        assert.equal(r.ok, true);
    } finally {
        cleanup(ctx);
    }
});

test('role worker cannot send cross-team', async () => {
    const ctx = setup();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-a', from_worker: 'dev-a',
                to_team: 'team-b', to_worker: 'pm-b', body: 'hi',
            }, paneDeps),
            /cannot send cross-team/
        );
    } finally {
        cleanup(ctx);
    }
});

// ── role guard: recipient side (gateway) ──

test('cross-team into a role team must address an orchestrator', async () => {
    const ctx = setup();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-a', from_worker: 'pm-a',
                to_team: 'team-b', to_worker: 'dev-b', body: 'hi',
            }, paneDeps),
            /must address one of its orchestrators \(pm-b\)/
        );
        assert.equal(readSpool(ctx.teamB.stateRoot, 'dev-b').length, 0);
    } finally {
        cleanup(ctx);
    }
});

test('gateway guard applies to legacy senders too (legacy team → role team)', async () => {
    const ctx = setup();
    try {
        process.env.MY_TEAM_STATE_ROOT = ctx.teamC.stateRoot;
        await assert.rejects(
            () => runApiSendMessage({
                team_name: 'team-c', from_worker: 'carol',
                to_team: 'team-b', to_worker: 'dev-b', body: 'hi',
            }, paneDeps),
            /must address one of its orchestrators/
        );
    } finally {
        cleanup(ctx);
    }
});

// ── legacy teams stay peer-symmetric ──

test('legacy team without roles has no guard: worker-to-worker initiation still works', async () => {
    const ctx = setup();
    try {
        process.env.MY_TEAM_STATE_ROOT = ctx.teamC.stateRoot;
        const r = await runApiSendMessage({
            team_name: 'team-c', from_worker: 'carol', to_worker: 'dan', body: 'peer hello',
        }, paneDeps);
        assert.equal(r.ok, true);
        assert.equal(readSpool(ctx.teamC.stateRoot, 'dan').length, 1);

        const cross = await runApiSendMessage({
            team_name: 'team-c', from_worker: 'carol',
            to_team: 'team-b', to_worker: 'pm-b', body: 'legacy cross-team to orchestrator',
        }, paneDeps);
        assert.equal(cross.ok, true);
    } finally {
        cleanup(ctx);
    }
});
