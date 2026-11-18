/**
 * Concurrency tests for the v2 mailbox pipeline.
 *
 * Scenario A: many senders → one recipient. The incoming-spool design
 * promises that one-file-per-message keeps every drop intact even when
 * sends arrive at the same time. This test asserts that promise.
 *
 * Scenario C: one worker triggers mailbox-list (spool absorption) and
 * mark-delivered concurrently. With atomic writes (write-temp + rename)
 * and per-worker ownership, all archive lines should survive and the
 * mailbox should converge to a consistent state.
 *
 * These tests use Promise.all to interleave calls; they do not fork
 * processes. Node's single-threaded event loop makes deterministic
 * lost-update reproduction hard — what we verify is that the data plane
 * survives interleaved fs reads/writes and reports no lost messages.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import {
    mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync,
} from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiSendMessage } from '../../src/commands/api/send-message.js';
import { runApiMailboxList } from '../../src/commands/api/mailbox-list.js';
import { runApiMailboxMarkDelivered } from '../../src/commands/api/mailbox-mark-delivered.js';
import { MAILBOX_SCHEMA_VERSION } from '../../src/lib/tmux-comm.js';

function setupTeam({ teamName = 't1', workers = ['alice', 'bob'] } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(stateRoot, { recursive: true });
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });

    const manifest = {
        team_name: teamName,
        state_root: stateRoot,
        workers: workers.map((name) => ({ name, pane_id: '%0', inbox_path: '' })),
    };
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    delete process.env.MY_TEAM_STATE_ROOT;
    rmSync(ctx.base, { recursive: true, force: true });
}

function readSpoolFiles(ctx, worker) {
    const dir = join(ctx.stateRoot, 'incoming-spool', worker);
    if (!existsSync(dir)) return [];
    return readdirSync(dir)
        .filter((n) => n.endsWith('.json'))
        .map((n) => JSON.parse(readFileSync(join(dir, n), 'utf-8')));
}

function readArchiveLines(ctx, worker) {
    const f = join(ctx.stateRoot, 'archive', `${worker}.jsonl`);
    if (!existsSync(f)) return [];
    return readFileSync(f, 'utf-8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
}

function readMailbox(ctx, worker) {
    const f = join(ctx.stateRoot, 'mailbox', `${worker}.json`);
    if (!existsSync(f)) return { schema_version: MAILBOX_SCHEMA_VERSION, inbox: {}, sent_pending: {} };
    return JSON.parse(readFileSync(f, 'utf-8'));
}

// ── Scenario A ───────────────────────────────────────────────────────────

test('SCENARIO A: 20 concurrent senders → one recipient, every spool file survives', async () => {
    const senders = Array.from({ length: 20 }, (_, i) => `s${i}`);
    const ctx = setupTeam({ workers: ['bob', ...senders] });
    try {
        const results = await Promise.all(
            senders.map((s, i) =>
                runApiSendMessage({
                    team_name: ctx.teamName,
                    from_worker: s,
                    to_worker: 'bob',
                    body: `msg from ${s} #${i}`,
                })
            )
        );
        // All sends accepted.
        assert.equal(results.length, 20);
        assert.ok(results.every((r) => r.ok && r.delivered_to === 'bob'));

        // Each sender produced a unique message_id.
        const ids = results.map((r) => r.message_id);
        assert.equal(new Set(ids).size, 20, 'all message_ids are unique');

        // All 20 spool files exist on disk.
        const spool = readSpoolFiles(ctx, 'bob');
        assert.equal(spool.length, 20, `expected 20 spool files, got ${spool.length}`);

        // After absorption, all 20 messages land in bob's inbox.
        const listResult = await runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' });
        assert.equal(listResult.messages.length, 20, 'all 20 messages absorbed');
        assert.equal(new Set(listResult.messages.map((m) => m.message_id)).size, 20);
    } finally {
        cleanup(ctx);
    }
});

test('SCENARIO A: concurrent sends do not corrupt the recipient mailbox JSON', async () => {
    const senders = Array.from({ length: 10 }, (_, i) => `s${i}`);
    const ctx = setupTeam({ workers: ['bob', ...senders] });
    try {
        await Promise.all(
            senders.map((s) =>
                runApiSendMessage({
                    team_name: ctx.teamName,
                    from_worker: s,
                    to_worker: 'bob',
                    body: `from ${s}`,
                })
            )
        );
        // Absorb and verify the JSON parses cleanly.
        await runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' });
        const mbox = readMailbox(ctx, 'bob');
        assert.equal(mbox.schema_version, MAILBOX_SCHEMA_VERSION);
        assert.equal(typeof mbox.inbox, 'object');
        assert.equal(Object.keys(mbox.inbox).length, 10);
    } finally {
        cleanup(ctx);
    }
});

// ── Scenario C ───────────────────────────────────────────────────────────

test('SCENARIO C: interleaved mailbox-list + mark-delivered preserves every archive line', async () => {
    const ctx = setupTeam({ workers: ['bob', 'alice'] });
    try {
        // Pre-populate bob's inbox by sending 10 messages from alice.
        const sendResults = [];
        for (let i = 0; i < 10; i++) {
            sendResults.push(
                await runApiSendMessage({
                    team_name: ctx.teamName,
                    from_worker: 'alice',
                    to_worker: 'bob',
                    body: `msg ${i}`,
                })
            );
        }
        // Absorb spool so messages are in inbox.
        await runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' });

        // Now interleave: each iteration does mark-delivered + mailbox-list in
        // parallel. Both touch bob.json but bob is the sole writer for both.
        const tasks = [];
        for (const r of sendResults) {
            tasks.push(runApiMailboxMarkDelivered({
                team_name: ctx.teamName, worker: 'bob', message_id: r.message_id,
            }));
            tasks.push(runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' }));
        }
        const settled = await Promise.allSettled(tasks);

        // All mark-delivered calls succeed (no thrown errors).
        const markCalls = settled.filter((_, idx) => idx % 2 === 0);
        const failedMarks = markCalls.filter((s) => s.status === 'rejected');
        assert.equal(failedMarks.length, 0,
            `mark-delivered failures: ${failedMarks.map((f) => f.reason?.message).join('; ')}`);

        // Every original message has exactly one direction:in archive line.
        const archive = readArchiveLines(ctx, 'bob');
        const inLines = archive.filter((e) => e.direction === 'in');
        const archivedIds = new Set(inLines.map((e) => e.message_id));
        assert.equal(archivedIds.size, 10, `expected 10 archived msgs, got ${archivedIds.size}`);

        // Mailbox inbox should be empty after all marks.
        const finalList = await runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' });
        assert.equal(finalList.messages.length, 0, 'inbox drained');
    } finally {
        cleanup(ctx);
    }
});

test('SCENARIO C: concurrent mailbox-list calls on a worker do not crash', async () => {
    const ctx = setupTeam();
    try {
        await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', body: 'hi',
        });
        const results = await Promise.all([
            runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' }),
            runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' }),
            runApiMailboxList({ team_name: ctx.teamName, worker: 'bob' }),
        ]);
        assert.ok(results.every((r) => r.ok));
        // The message is absorbed exactly once — subsequent reads still see it
        // (it's in inbox until mark-delivered, which we don't call here).
        const mbox = readMailbox(ctx, 'bob');
        assert.equal(Object.keys(mbox.inbox).length, 1);
    } finally {
        cleanup(ctx);
    }
});
