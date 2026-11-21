/**
 * Mailbox durability: spool absorption must not lose a message when the mailbox write fails.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { absorbIncomingSpool } from '../../src/lib/tmux-comm.js';

function setupTeam(teamName = 't1') {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    rmSync(ctx.base, { recursive: true, force: true });
}

function dropSpool(ctx, worker, id) {
    const dir = join(ctx.stateRoot, 'incoming-spool', worker);
    mkdirSync(dir, { recursive: true });
    const file = join(dir, `${id}.json`);
    writeFileSync(file, JSON.stringify({
        message_id: id, from_worker: 'alice', to_worker: worker, body: `body ${id}`,
        reply_to: null, expects_reply: false, created_at: new Date().toISOString(),
    }));
    return file;
}

test('E3: a spool file survives when the mailbox write fails', async () => {
    const ctx = setupTeam();
    try {
        const spool = dropSpool(ctx, 'bob', 'm1');
        // A non-empty directory where bob.json belongs makes the rename in atomicWriteJson fail.
        mkdirSync(join(ctx.stateRoot, 'mailbox', 'bob.json', 'blocker'), { recursive: true });

        await assert.rejects(absorbIncomingSpool(ctx.teamName, 'bob', ctx.base));
        assert.ok(existsSync(spool), 'spool file must remain until the mailbox write succeeds');
    } finally {
        cleanup(ctx);
    }
});
