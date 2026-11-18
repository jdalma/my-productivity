/**
 * `my-team status` must surface what a worker cannot shout about itself:
 * its self-reported state (status.json) and mail that is stuck — spool files
 * never absorbed, inbox entries never consumed, questions never answered.
 * Without these the only way to notice a stalled worker is to open its pane.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runStatus } from '../../src/commands/status.js';
import { MAILBOX_SCHEMA_VERSION } from '../../src/lib/tmux-comm.js';

function setup() {
    const base = mkdtempSync(join(tmpdir(), 'my-team-status-'));
    const stateRoot = join(base, 'demo');
    for (const d of ['mailbox', 'incoming-spool/dev', 'workers/pm', 'workers/dev']) {
        mkdirSync(join(stateRoot, d), { recursive: true });
    }
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify({
        team_name: 'demo', state_root: stateRoot, session_name: 'my-team-demo-x:0',
        session_mode: 'detached-session', started_at: '2026-01-01T00:00:00Z',
        workers: [
            { name: 'pm', pane_id: '%1', cwd: '/tmp/a', agent_type: 'claude' },
            { name: 'dev', pane_id: '%2', cwd: '/tmp/b', agent_type: 'claude' },
        ],
    }));
    writeFileSync(join(stateRoot, 'workers/dev/status.json'), JSON.stringify({
        state: 'blocked', reason: 'aws sso login needed', updated_at: '2026-01-02T00:00:00Z',
    }));
    writeFileSync(join(stateRoot, 'mailbox/pm.json'), JSON.stringify({
        schema_version: MAILBOX_SCHEMA_VERSION, worker: 'pm',
        inbox: { m1: { message_id: 'm1', from_worker: 'dev', body: 'x', created_at: '2026-01-01T01:00:00Z' } },
        sent_pending: {
            q1: { message_id: 'q1', to_worker: 'dev', body: 'q', expects_reply: true, sent_at: '2026-01-01T02:00:00Z' },
            q2: { message_id: 'q2', to_worker: 'dev', body: 'q', expects_reply: true, sent_at: '2026-01-01T03:00:00Z' },
        },
    }));
    writeFileSync(join(stateRoot, 'incoming-spool/dev/s1.json'), JSON.stringify({ message_id: 's1', from_worker: 'pm', body: 'y' }));
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return base;
}

async function statusJson() {
    const lines = [];
    const orig = console.log;
    console.log = (s) => lines.push(String(s));
    try { await runStatus({ team: 'demo', json: true }); } finally { console.log = orig; }
    return JSON.parse(lines.join('\n'));
}

test('status --json reports self-reported state and stuck mail per worker', async () => {
    const base = setup();
    try {
        const out = await statusJson();
        const pm = out.workers.find((w) => w.name === 'pm');
        const dev = out.workers.find((w) => w.name === 'dev');

        assert.equal(pm.state, null, 'no status.json → null state');
        assert.equal(pm.unread, 1);
        assert.equal(pm.sent_pending, 2);
        assert.equal(pm.oldest_pending_at, '2026-01-01T02:00:00Z');
        assert.equal(pm.spool, 0);

        assert.equal(dev.state, 'blocked');
        assert.equal(dev.reason, 'aws sso login needed');
        assert.equal(dev.spool, 1, 'a spool file the worker never absorbed');
        assert.equal(dev.unread, 0);
        assert.equal(dev.sent_pending, 0);
        assert.equal(dev.oldest_pending_at, null);
    } finally {
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
});
