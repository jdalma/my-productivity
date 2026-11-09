/**
 * Unit tests for `my-team remove-worker` (mid-session worker removal).
 *
 * Same fixture pattern as add-worker.test.js: mkdtemp state_root +
 * MY_TEAM_STATE_ROOT_BASE so loadManifest resolves by team name. tmux-touching
 * functions (killPane / sendToWorker) are injected via the `deps` seam; the
 * manifest write runs for real and is asserted on disk.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runRemoveWorker } from '../../src/commands/remove-worker.js';

function setupTeam({ teamName = 't1', workers = ['alice', 'bob', 'carol'] } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(stateRoot, { recursive: true });
    const manifest = {
        team_name: teamName,
        state_root: stateRoot,
        session_name: 'test-session',
        session_mode: 'split-pane',
        leader_pane: '%0',
        workers: workers.map((w, i) => {
            // Accept a bare name (legacy peer team) or {name, role} so a test
            // can build a role-declaring team.
            const { name, role } = typeof w === 'string' ? { name: w, role: undefined } : w;
            const entry = { name, pane_id: `%${i + 1}`, cwd: tmpdir(), agent_type: 'claude', overlay_path: '' };
            if (role !== undefined) entry.role = role;
            return entry;
        }),
    };
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    rmSync(ctx.base, { recursive: true, force: true });
}

/**
 * Write worker `from`'s mailbox with one open question addressed to `to`.
 * This is the on-disk fact remove-worker reads to decide who is actually
 * affected by the removal (tmux-comm.js records to_worker in sent_pending).
 */
function seedPendingQuestion(ctx, from, to) {
    mkdirSync(join(ctx.stateRoot, 'mailbox'), { recursive: true });
    writeFileSync(join(ctx.stateRoot, 'mailbox', `${from}.json`), JSON.stringify({
        schema_version: 2,
        worker: from,
        inbox: {},
        sent_pending: { 'msg-1': { to_worker: to, body: 'still there?', expects_reply: true, sent_at: '2026-01-01T00:00:00Z' } },
    }), 'utf-8');
}

const readManifest = (ctx) => JSON.parse(readFileSync(join(ctx.stateRoot, 'manifest.json'), 'utf-8'));

function spyDeps() {
    const killed = [];
    const notified = [];
    return {
        killed, notified,
        deps: {
            killPane: async (id) => { killed.push(id); },
            sendToWorker: async (_s, paneId, msg) => { notified.push([paneId, msg]); return true; },
        },
    };
}

test('removes the worker from the roster, kills its pane, notifies the rest', async () => {
    const ctx = setupTeam();
    const { killed, notified, deps } = spyDeps();
    try {
        const res = await runRemoveWorker({ team: 't1', name: 'bob' }, deps);
        assert.equal(res.pane_id, '%2');
        assert.deepEqual(readManifest(ctx).workers.map((w) => w.name), ['alice', 'carol']);
        assert.deepEqual(killed, ['%2']);
        // Peer team, nobody waiting on bob: the notice falls back to everyone
        // (otherwise the removal would be silent for a team with no orchestrator).
        assert.deepEqual(notified.map(([p]) => p), ['%1', '%3']);
        assert.match(notified[0][1], /'bob' finished its assignment and has LEFT/);
    } finally { cleanup(ctx); }
});

test('rejects an unknown worker without touching the manifest or any pane', async () => {
    const ctx = setupTeam();
    const { killed, deps } = spyDeps();
    try {
        await assert.rejects(
            () => runRemoveWorker({ team: 't1', name: 'nobody' }, deps),
            /not in team/
        );
        assert.equal(readManifest(ctx).workers.length, 3);
        assert.deepEqual(killed, []);
    } finally { cleanup(ctx); }
});

test('never kills the leader pane', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    // Force the worker's pane_id to equal leader_pane (split-pane host edge case).
    const m = readManifest(ctx);
    m.workers[0].pane_id = m.leader_pane;
    writeFileSync(join(ctx.stateRoot, 'manifest.json'), JSON.stringify(m), 'utf-8');
    const { killed, deps } = spyDeps();
    try {
        await runRemoveWorker({ team: 't1', name: 'alice' }, deps);
        assert.deepEqual(killed, []);
        assert.equal(readManifest(ctx).workers.length, 0);
    } finally { cleanup(ctx); }
});

test('a failing departure notice does not undo the removal', async () => {
    const ctx = setupTeam();
    const { killed } = spyDeps();
    try {
        await runRemoveWorker({ team: 't1', name: 'bob' }, {
            killPane: async (id) => { killed.push(id); },
            sendToWorker: async () => { throw new Error('pane busy'); },
        });
        assert.deepEqual(readManifest(ctx).workers.map((w) => w.name), ['alice', 'carol']);
        assert.deepEqual(killed, ['%2']);
    } finally { cleanup(ctx); }
});

test('only the waiting worker and the orchestrator are told about a removal', async () => {
    // alice orchestrates; carol has an open question to bob; dave is unrelated.
    const ctx = setupTeam({
        workers: [
            { name: 'alice', role: 'orchestrator' },
            { name: 'bob', role: 'worker' },
            { name: 'carol', role: 'worker' },
            { name: 'dave', role: 'worker' },
        ],
    });
    seedPendingQuestion(ctx, 'carol', 'bob');
    const { notified, deps } = spyDeps();
    try {
        await runRemoveWorker({ team: 't1', name: 'bob' }, deps);
        const panes = notified.map(([p]) => p).sort();
        // %1 = alice (orchestrator, keeps the work map), %3 = carol (waiting).
        // %4 = dave learns from the roster on his next mailbox-list instead.
        assert.deepEqual(panes, ['%1', '%3']);
        assert.match(notified[0][1], /finished its assignment/);
    } finally { cleanup(ctx); }
});

test('waiting workers are read from the removed team, not the caller\'s MY_TEAM_STATE_ROOT', async () => {
    // A worker pane carries MY_TEAM_STATE_ROOT for its own team. remove-worker must still read the
    // mailboxes of the team it removes from.
    const ctx = setupTeam({
        workers: [{ name: 'alice', role: 'orchestrator' }, { name: 'bob', role: 'worker' }, { name: 'carol', role: 'worker' }],
    });
    seedPendingQuestion(ctx, 'carol', 'bob');
    const other = mkdtempSync(join(tmpdir(), 'my-team-other-'));
    const saved = process.env.MY_TEAM_STATE_ROOT;
    process.env.MY_TEAM_STATE_ROOT = other;
    const { notified, deps } = spyDeps();
    try {
        await runRemoveWorker({ team: 't1', name: 'bob' }, deps);
        assert.deepEqual(notified.map(([p]) => p).sort(), ['%1', '%3']);
    } finally {
        if (saved === undefined) delete process.env.MY_TEAM_STATE_ROOT; else process.env.MY_TEAM_STATE_ROOT = saved;
        rmSync(other, { recursive: true, force: true });
        cleanup(ctx);
    }
});

test('an unreadable mailbox does not block the removal or the other notices', async () => {
    const ctx = setupTeam({
        workers: [{ name: 'alice', role: 'orchestrator' }, { name: 'bob', role: 'worker' }, { name: 'carol', role: 'worker' }],
    });
    mkdirSync(join(ctx.stateRoot, 'mailbox'), { recursive: true });
    writeFileSync(join(ctx.stateRoot, 'mailbox', 'carol.json'), '{ not json', 'utf-8');
    const { notified, deps } = spyDeps();
    try {
        await runRemoveWorker({ team: 't1', name: 'bob' }, deps);
        assert.deepEqual(readManifest(ctx).workers.map((w) => w.name), ['alice', 'carol']);
        // carol's mailbox is unreadable so she cannot be classified as waiting;
        // the orchestrator is still notified.
        assert.deepEqual(notified.map(([p]) => p), ['%1']);
    } finally { cleanup(ctx); }
});
