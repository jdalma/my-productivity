/**
 * Unit tests for `my-team api mailbox-list` (schema v2, Phase B).
 *
 * Behavior:
 *   - Absorbs incoming-spool files into mailbox.inbox before returning.
 *     Spool files are deleted after absorption.
 *   - When an absorbed message carries a known reply_to, the matching entry
 *     in sent_pending is removed (correlation resolved).
 *   - Returns inbox as a created_at-sorted array and sent_pending as a
 *     sent_at-sorted array.
 *
 * mailbox-list is now async because spool absorption involves fs/promises.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiMailboxList } from '../../src/commands/api/mailbox-list.js';
import { MAILBOX_SCHEMA_VERSION } from '../../src/lib/tmux-comm.js';

function setupTeam({ teamName = 't1', worker = 'alice', mailbox = null, spool = [] } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(stateRoot, { recursive: true });
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });

    const manifest = {
        team_name: teamName,
        state_root: stateRoot,
        workers: [
            { name: worker, pane_id: '%99', inbox_path: join(stateRoot, 'workers', worker, 'inbox.md') },
        ],
    };
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');

    if (mailbox !== null) {
        const mailboxFile = join(stateRoot, 'mailbox', `${worker}.json`);
        writeFileSync(mailboxFile, JSON.stringify(mailbox), 'utf-8');
    }

    if (spool.length > 0) {
        const spoolDir = join(stateRoot, 'incoming-spool', worker);
        mkdirSync(spoolDir, { recursive: true });
        for (const msg of spool) {
            writeFileSync(join(spoolDir, `${msg.message_id}.json`), JSON.stringify(msg), 'utf-8');
        }
    }

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName, worker };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    delete process.env.MY_TEAM_STATE_ROOT;
    rmSync(ctx.base, { recursive: true, force: true });
}

function spoolFiles(ctx) {
    const dir = join(ctx.stateRoot, 'incoming-spool', ctx.worker);
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter((n) => n.endsWith('.json'));
}

test('mailbox-list requires team_name', async () => {
    await assert.rejects(() => runApiMailboxList({ worker: 'alice' }), /team_name is required/);
});

test('mailbox-list requires worker', async () => {
    await assert.rejects(() => runApiMailboxList({ team_name: 't1' }), /worker is required/);
});

test('mailbox-list returns empty when mailbox file and spool are missing', async () => {
    const ctx = setupTeam({ mailbox: null });
    try {
        const result = await runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker });
        assert.equal(result.ok, true);
        assert.deepEqual(result.messages, []);
        assert.deepEqual(result.sent_pending, []);
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list absorbs spool files into inbox and deletes them', async () => {
    const ctx = setupTeam({
        mailbox: { schema_version: MAILBOX_SCHEMA_VERSION, worker: 'alice', inbox: {}, sent_pending: {} },
        spool: [
            { message_id: 's-1', from_worker: 'bob', to_worker: 'alice', body: 'hi', reply_to: null, expects_reply: false, created_at: '2026-01-01T00:00:00Z' },
            { message_id: 's-2', from_worker: 'bob', to_worker: 'alice', body: 'second', reply_to: null, expects_reply: false, created_at: '2026-01-02T00:00:00Z' },
        ],
    });
    try {
        const result = await runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker });
        assert.deepEqual(result.messages.map((m) => m.message_id), ['s-1', 's-2']);
        // Spool dir must be empty after absorption.
        assert.deepEqual(spoolFiles(ctx), []);
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list spool absorption resolves matching sent_pending entry (reply correlation)', async () => {
    const ctx = setupTeam({
        mailbox: {
            schema_version: MAILBOX_SCHEMA_VERSION,
            worker: 'alice',
            inbox: {},
            sent_pending: {
                'q-1': { message_id: 'q-1', to_worker: 'bob', body: 'q', expects_reply: true, sent_at: '2026-01-01T00:00:00Z' },
            },
        },
        spool: [
            { message_id: 'r-1', from_worker: 'bob', to_worker: 'alice', body: 'a', reply_to: 'q-1', expects_reply: false, created_at: '2026-01-01T00:01:00Z' },
        ],
    });
    try {
        const result = await runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker });
        assert.equal(result.messages.length, 1);
        assert.equal(result.messages[0].message_id, 'r-1');
        // sent_pending[q-1] should be gone — reply absorbed it.
        assert.deepEqual(result.sent_pending, []);
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list returns unread inbox entries sorted by created_at', async () => {
    const ctx = setupTeam({
        mailbox: {
            schema_version: MAILBOX_SCHEMA_VERSION,
            worker: 'alice',
            inbox: {
                'b-2': { message_id: 'b-2', from_worker: 'bob', body: 'second', created_at: '2026-01-02T00:00:00Z' },
                'a-1': { message_id: 'a-1', from_worker: 'bob', body: 'first',  created_at: '2026-01-01T00:00:00Z' },
                'c-3': { message_id: 'c-3', from_worker: 'carol', body: 'third', created_at: '2026-01-03T00:00:00Z' },
            },
            sent_pending: {},
        },
    });
    try {
        const result = await runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker });
        assert.deepEqual(result.messages.map((m) => m.message_id), ['a-1', 'b-2', 'c-3']);
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list filters consumed_at when unread_only (default)', async () => {
    const ctx = setupTeam({
        mailbox: {
            schema_version: MAILBOX_SCHEMA_VERSION,
            worker: 'alice',
            inbox: {
                'm1': { message_id: 'm1', body: 'old', created_at: '2026-01-01T00:00:00Z', consumed_at: '2026-01-01T01:00:00Z' },
                'm2': { message_id: 'm2', body: 'new', created_at: '2026-01-02T00:00:00Z', consumed_at: null },
                'm3': { message_id: 'm3', body: 'newer', created_at: '2026-01-03T00:00:00Z' },
            },
            sent_pending: {},
        },
    });
    try {
        const result = await runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker });
        assert.deepEqual(result.messages.map((m) => m.message_id), ['m2', 'm3']);
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list returns sent_pending sorted by sent_at', async () => {
    const ctx = setupTeam({
        mailbox: {
            schema_version: MAILBOX_SCHEMA_VERSION,
            worker: 'alice',
            inbox: {},
            sent_pending: {
                'q-b': { message_id: 'q-b', to_worker: 'bob', body: 'q1', expects_reply: true, sent_at: '2026-01-02T00:00:00Z' },
                'q-a': { message_id: 'q-a', to_worker: 'bob', body: 'q0', expects_reply: true, sent_at: '2026-01-01T00:00:00Z' },
            },
        },
    });
    try {
        const result = await runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker });
        assert.deepEqual(result.sent_pending.map((m) => m.message_id), ['q-a', 'q-b']);
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list throws on malformed mailbox JSON', async () => {
    const ctx = setupTeam({ mailbox: null });
    try {
        const mailboxFile = join(ctx.stateRoot, 'mailbox', `${ctx.worker}.json`);
        writeFileSync(mailboxFile, '{ not valid json', 'utf-8');
        await assert.rejects(
            () => runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker }),
            /is not valid JSON/
        );
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list throws on schema_version mismatch', async () => {
    const ctx = setupTeam({
        mailbox: {
            schema_version: 1,
            worker: 'alice',
            messages: [{ message_id: 'legacy', body: 'old' }],
        },
    });
    try {
        await assert.rejects(
            () => runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker }),
            /schema_version=1/
        );
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list throws when schema_version field is missing (legacy v1 file)', async () => {
    const ctx = setupTeam({
        mailbox: {
            worker: 'alice',
            messages: [{ message_id: 'legacy', body: 'old' }],
        },
    });
    try {
        await assert.rejects(
            () => runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker }),
            /schema_version=missing/
        );
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list rejects worker name made entirely of disallowed characters', async () => {
    // sanitizeName strips non-alphanumeric/hyphen characters; "../" yields ""
    // which is rejected. This is the defense against path traversal attempts.
    await assert.rejects(
        () => runApiMailboxList({ team_name: 't1', worker: '../' }),
        /no valid characters/
    );
});

test('mailbox-list sanitizer strips traversal characters before path resolution', async () => {
    // Input "../etc" sanitizes to "etc" (a benign short name). Path
    // resolution therefore stays inside the team root. This test asserts
    // that the resolved mailbox path does not escape the configured root.
    const ctx = setupTeam({ worker: 'etc', mailbox: null });
    try {
        // No mailbox file → empty response, confirming we're inside the team root.
        const result = await runApiMailboxList({ team_name: ctx.teamName, worker: '../etc' });
        assert.equal(result.ok, true);
        assert.equal(result.worker, 'etc');
    } finally {
        cleanup(ctx);
    }
});

test('mailbox-list returns the live team roster from the manifest on every call', async () => {
    const ctx = setupTeam({ mailbox: null });
    try {
        // add-worker appended a peer after this worker booted; its AGENTS.md
        // roster is stale, the manifest is not.
        const manifestPath = join(ctx.stateRoot, 'manifest.json');
        const m = JSON.parse(readFileSync(manifestPath, 'utf-8'));
        m.workers[0].agent_type = 'claude';
        m.workers[0].role = 'orchestrator';
        m.workers[0].description = 'PM hub';
        m.workers.push({ name: 'newbie', pane_id: '%5', agent_type: 'codex', role: 'worker', description: 'joined late' });
        writeFileSync(manifestPath, JSON.stringify(m), 'utf-8');

        const res = await runApiMailboxList({ team_name: ctx.teamName, worker: ctx.worker });
        assert.deepEqual(res.roster, [
            { name: 'alice', agent_type: 'claude', role: 'orchestrator', description: 'PM hub' },
            { name: 'newbie', agent_type: 'codex', role: 'worker', description: 'joined late' },
        ]);
    } finally {
        cleanup(ctx);
    }
});
