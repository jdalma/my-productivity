/**
 * Unit tests for `my-team api mailbox-mark-delivered` (schema v2).
 *
 * On delivery the handler:
 *   - removes the entry from inbox map
 *   - appends a "direction: in" line (with consumed_at) to archive jsonl
 *
 * Idempotency: re-marking a message that is no longer in inbox but exists in
 * the archive returns already_consumed=true.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiMailboxMarkDelivered } from '../../src/commands/api/mailbox-mark-delivered.js';
import { MAILBOX_SCHEMA_VERSION } from '../../src/lib/tmux-comm.js';

function setupTeam({ teamName = 't1', worker = 'alice', inbox = {} } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(stateRoot, { recursive: true });
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });

    const manifest = {
        team_name: teamName,
        state_root: stateRoot,
        workers: [{ name: worker, pane_id: '%99', inbox_path: '' }],
    };
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');

    const mailboxFile = join(stateRoot, 'mailbox', `${worker}.json`);
    writeFileSync(
        mailboxFile,
        JSON.stringify({ schema_version: MAILBOX_SCHEMA_VERSION, worker, inbox, sent_pending: {} }),
        'utf-8'
    );

    const archiveFile = join(stateRoot, 'archive', `${worker}.jsonl`);

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName, worker, mailboxFile, archiveFile };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    delete process.env.MY_TEAM_STATE_ROOT;
    rmSync(ctx.base, { recursive: true, force: true });
}

function readMailbox(ctx) {
    return JSON.parse(readFileSync(ctx.mailboxFile, 'utf-8'));
}

function readArchiveLines(ctx) {
    if (!existsSync(ctx.archiveFile)) return [];
    return readFileSync(ctx.archiveFile, 'utf-8')
        .split('\n')
        .filter((l) => l.trim())
        .map((l) => JSON.parse(l));
}

test('mark-delivered requires team_name', () => {
    assert.throws(() => runApiMailboxMarkDelivered({ worker: 'alice', message_id: '1' }), /team_name is required/);
});

test('mark-delivered requires worker', () => {
    assert.throws(() => runApiMailboxMarkDelivered({ team_name: 't1', message_id: '1' }), /worker is required/);
});

test('mark-delivered requires message_id', () => {
    assert.throws(() => runApiMailboxMarkDelivered({ team_name: 't1', worker: 'alice' }), /message_id is required/);
});

test('mark-delivered removes entry from inbox and writes archive line', () => {
    const ctx = setupTeam({
        inbox: {
            'm1': { message_id: 'm1', from_worker: 'bob', body: 'a', created_at: '2026-01-01T00:00:00Z' },
            'm2': { message_id: 'm2', from_worker: 'bob', body: 'b', created_at: '2026-01-02T00:00:00Z' },
        },
    });
    try {
        const before = Date.now();
        const result = runApiMailboxMarkDelivered({
            team_name: ctx.teamName, worker: ctx.worker, message_id: 'm2',
        });
        const after = Date.now();
        assert.equal(result.ok, true);
        assert.equal(result.message_id, 'm2');

        const mbox = readMailbox(ctx);
        assert.equal(mbox.schema_version, MAILBOX_SCHEMA_VERSION);
        assert.ok(mbox.inbox.m1, 'm1 unchanged');
        assert.equal(mbox.inbox.m2, undefined, 'm2 removed from inbox');

        const archive = readArchiveLines(ctx);
        assert.equal(archive.length, 1);
        assert.equal(archive[0].message_id, 'm2');
        assert.equal(archive[0].direction, 'in');
        assert.equal(archive[0].body, 'b');
        const ts = Date.parse(archive[0].consumed_at);
        assert.ok(ts >= before && ts <= after, `consumed_at within window: ${archive[0].consumed_at}`);
    } finally {
        cleanup(ctx);
    }
});

test('mark-delivered is idempotent when already archived', () => {
    const ctx = setupTeam({
        inbox: { 'm1': { message_id: 'm1', body: 'a', created_at: '2026-01-01T00:00:00Z' } },
    });
    try {
        runApiMailboxMarkDelivered({ team_name: ctx.teamName, worker: ctx.worker, message_id: 'm1' });
        const secondCall = runApiMailboxMarkDelivered({ team_name: ctx.teamName, worker: ctx.worker, message_id: 'm1' });
        assert.equal(secondCall.ok, true);
        assert.equal(secondCall.already_consumed, true);
        const archive = readArchiveLines(ctx);
        assert.equal(archive.length, 1, 'archive line is not duplicated');
    } finally {
        cleanup(ctx);
    }
});

test('mark-delivered throws on unknown message_id when nothing archived', () => {
    const ctx = setupTeam({
        inbox: { 'm1': { message_id: 'm1', body: 'a', created_at: '2026-01-01T00:00:00Z' } },
    });
    try {
        assert.throws(
            () => runApiMailboxMarkDelivered({
                team_name: ctx.teamName, worker: ctx.worker, message_id: 'unknown',
            }),
            /message_id 'unknown' not found/
        );
    } finally {
        cleanup(ctx);
    }
});

test('mark-delivered throws when mailbox file missing', () => {
    const ctx = setupTeam({ inbox: {} });
    try {
        rmSync(ctx.mailboxFile);
        assert.throws(
            () => runApiMailboxMarkDelivered({
                team_name: ctx.teamName, worker: ctx.worker, message_id: 'm1',
            }),
            /mailbox not found/
        );
    } finally {
        cleanup(ctx);
    }
});

test('mark-delivered throws on schema_version mismatch', () => {
    const ctx = setupTeam({ inbox: {} });
    try {
        writeFileSync(
            ctx.mailboxFile,
            JSON.stringify({ schema_version: 1, worker: ctx.worker, messages: [{ message_id: 'm1' }] }),
            'utf-8'
        );
        assert.throws(
            () => runApiMailboxMarkDelivered({
                team_name: ctx.teamName, worker: ctx.worker, message_id: 'm1',
            }),
            /schema_version=1/
        );
    } finally {
        cleanup(ctx);
    }
});

test('mark-delivered throws when schema_version field is missing', () => {
    const ctx = setupTeam({ inbox: {} });
    try {
        writeFileSync(
            ctx.mailboxFile,
            JSON.stringify({ worker: ctx.worker, messages: [{ message_id: 'm1' }] }),
            'utf-8'
        );
        assert.throws(
            () => runApiMailboxMarkDelivered({
                team_name: ctx.teamName, worker: ctx.worker, message_id: 'm1',
            }),
            /schema_version=missing/
        );
    } finally {
        cleanup(ctx);
    }
});

test('mark-delivered rejects worker name made entirely of disallowed characters', () => {
    assert.throws(
        () => runApiMailboxMarkDelivered({ team_name: 't1', worker: '../', message_id: 'm1' }),
        /no valid characters/
    );
});
