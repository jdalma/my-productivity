/**
 * Unit tests for cleanupWorkerCwdState (Phase D).
 *
 * Phase A-C introduced new per-cwd files (mailbox.json, archive/<w>.jsonl,
 * incoming-spool/<w>/). This cleanup helper removes them so a team teardown
 * does not leak v2 state.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { cleanupWorkerCwdState } from '../../src/lib/tmux-comm.js';

function setupCwd({ teamName = 't1', worker = 'alice' } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(stateRoot, { recursive: true });
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
    mkdirSync(join(stateRoot, 'archive'), { recursive: true });
    mkdirSync(join(stateRoot, 'incoming-spool', worker), { recursive: true });

    writeFileSync(join(stateRoot, 'mailbox', `${worker}.json`), '{}', 'utf-8');
    writeFileSync(join(stateRoot, 'archive', `${worker}.jsonl`), '{}\n', 'utf-8');
    writeFileSync(join(stateRoot, 'incoming-spool', worker, 'm1.json'), '{}', 'utf-8');
    writeFileSync(join(stateRoot, 'incoming-spool', worker, 'm2.json'), '{}', 'utf-8');

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    process.env.MY_TEAM_STATE_ROOT = stateRoot;
    return { base, stateRoot, teamName, worker };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    delete process.env.MY_TEAM_STATE_ROOT;
    rmSync(ctx.base, { recursive: true, force: true });
}

test('cleanupWorkerCwdState removes mailbox, archive, and incoming-spool', () => {
    const ctx = setupCwd();
    try {
        cleanupWorkerCwdState(ctx.teamName, ctx.worker, ctx.base);
        assert.equal(existsSync(join(ctx.stateRoot, 'mailbox', `${ctx.worker}.json`)), false);
        assert.equal(existsSync(join(ctx.stateRoot, 'archive', `${ctx.worker}.jsonl`)), false);
        assert.equal(existsSync(join(ctx.stateRoot, 'incoming-spool', ctx.worker)), false);
    } finally {
        cleanup(ctx);
    }
});

test('cleanupWorkerCwdState is a no-op when nothing exists', () => {
    const ctx = setupCwd();
    try {
        cleanupWorkerCwdState(ctx.teamName, 'someone-else', ctx.base);
        // Other worker's files unaffected.
        assert.equal(existsSync(join(ctx.stateRoot, 'mailbox', `${ctx.worker}.json`)), true);
    } finally {
        cleanup(ctx);
    }
});

test('cleanupWorkerCwdState ignores when cwd is missing', () => {
    cleanupWorkerCwdState('t1', 'alice', null);
    cleanupWorkerCwdState('t1', 'alice', undefined);
    // Should not throw — these are documented no-ops.
    assert.ok(true);
});
