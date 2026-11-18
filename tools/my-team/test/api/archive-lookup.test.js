/**
 * Unit tests for `my-team api archive-lookup` (Phase C).
 *
 * The archive is the durable record per worker. Workers query it to resolve
 * reply_to values that aren't (or no longer) in sent_pending.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiArchiveLookup } from '../../src/commands/api/archive-lookup.js';

function setupTeam({ teamName = 't1', worker = 'alice', archiveLines = [] } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(stateRoot, { recursive: true });
    mkdirSync(join(stateRoot, 'archive'), { recursive: true });

    const manifest = {
        team_name: teamName,
        state_root: stateRoot,
        workers: [{ name: worker, pane_id: '%0', inbox_path: '' }],
    };
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');

    if (archiveLines.length > 0) {
        const archiveFile = join(stateRoot, 'archive', `${worker}.jsonl`);
        writeFileSync(
            archiveFile,
            archiveLines.map((e) => JSON.stringify(e)).join('\n') + '\n',
            'utf-8'
        );
    }

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName, worker };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    delete process.env.MY_TEAM_STATE_ROOT;
    rmSync(ctx.base, { recursive: true, force: true });
}

test('archive-lookup requires team_name', () => {
    assert.throws(() => runApiArchiveLookup({ worker: 'alice', message_id: 'm1' }), /team_name is required/);
});

test('archive-lookup requires worker', () => {
    assert.throws(() => runApiArchiveLookup({ team_name: 't1', message_id: 'm1' }), /worker is required/);
});

test('archive-lookup requires message_id', () => {
    assert.throws(() => runApiArchiveLookup({ team_name: 't1', worker: 'alice' }), /message_id is required/);
});

test('archive-lookup returns found=false when archive file is missing', () => {
    const ctx = setupTeam();
    try {
        const result = runApiArchiveLookup({ team_name: ctx.teamName, worker: ctx.worker, message_id: 'unknown' });
        assert.equal(result.ok, true);
        assert.equal(result.found, false);
    } finally {
        cleanup(ctx);
    }
});

test('archive-lookup finds an out-direction entry I previously sent', () => {
    const ctx = setupTeam({
        archiveLines: [
            { message_id: 'm-1', from_worker: 'alice', to_worker: 'bob', body: 'q1', direction: 'out', created_at: '2026-01-01T00:00:00Z' },
            { message_id: 'm-2', from_worker: 'bob', to_worker: 'alice', body: 'a1', direction: 'in',  created_at: '2026-01-01T00:01:00Z', consumed_at: '2026-01-01T00:02:00Z' },
        ],
    });
    try {
        const result = runApiArchiveLookup({ team_name: ctx.teamName, worker: ctx.worker, message_id: 'm-1' });
        assert.equal(result.found, true);
        assert.equal(result.entry.direction, 'out');
        assert.equal(result.entry.to_worker, 'bob');
    } finally {
        cleanup(ctx);
    }
});

test('archive-lookup finds an in-direction entry I previously received', () => {
    const ctx = setupTeam({
        archiveLines: [
            { message_id: 'm-1', from_worker: 'alice', to_worker: 'bob', body: 'q1', direction: 'out', created_at: '2026-01-01T00:00:00Z' },
            { message_id: 'm-2', from_worker: 'bob', to_worker: 'alice', body: 'a1', direction: 'in',  created_at: '2026-01-01T00:01:00Z', consumed_at: '2026-01-01T00:02:00Z' },
        ],
    });
    try {
        const result = runApiArchiveLookup({ team_name: ctx.teamName, worker: ctx.worker, message_id: 'm-2' });
        assert.equal(result.found, true);
        assert.equal(result.entry.direction, 'in');
        assert.equal(result.entry.from_worker, 'bob');
    } finally {
        cleanup(ctx);
    }
});

test('archive-lookup returns found=false for unknown message_id', () => {
    const ctx = setupTeam({
        archiveLines: [
            { message_id: 'm-1', direction: 'out', created_at: '2026-01-01T00:00:00Z' },
        ],
    });
    try {
        const result = runApiArchiveLookup({ team_name: ctx.teamName, worker: ctx.worker, message_id: 'ghost' });
        assert.equal(result.found, false);
    } finally {
        cleanup(ctx);
    }
});

test('archive-lookup tolerates malformed lines and continues scanning', () => {
    const ctx = setupTeam();
    try {
        const archiveFile = join(ctx.stateRoot, 'archive', `${ctx.worker}.jsonl`);
        writeFileSync(
            archiveFile,
            'not valid json\n' +
            JSON.stringify({ message_id: 'm-1', direction: 'out' }) + '\n' +
            '{ broken\n',
            'utf-8'
        );
        const result = runApiArchiveLookup({ team_name: ctx.teamName, worker: ctx.worker, message_id: 'm-1' });
        assert.equal(result.found, true);
        assert.equal(result.entry.message_id, 'm-1');
    } finally {
        cleanup(ctx);
    }
});
