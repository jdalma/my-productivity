/**
 * Unit tests for `my-team api send-message` (schema v2, Phase B).
 *
 * Owner model:
 *   - Sender writes the recipient's incoming-spool file, the sender's own
 *     mailbox.sent_pending (when expects_reply=true), and the sender's own
 *     archive jsonl (direction: out).
 *   - The recipient mailbox.json is NOT touched on send — that happens when
 *     the recipient calls mailbox-list (spool→inbox absorption).
 *
 * Phase B additions:
 *   - expects_reply parameter (default false)
 *   - events.jsonl line carries message_id / reply_to / expects_reply
 *
 * No tmux pane exists in tests; sendTmuxTrigger silently returns false.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiSendMessage } from '../../src/commands/api/send-message.js';
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

function readMailbox(ctx, worker) {
    const f = join(ctx.stateRoot, 'mailbox', `${worker}.json`);
    if (!existsSync(f)) return { schema_version: MAILBOX_SCHEMA_VERSION, inbox: {}, sent_pending: {} };
    return JSON.parse(readFileSync(f, 'utf-8'));
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

function readEvents(ctx) {
    const f = join(ctx.stateRoot, 'events.jsonl');
    if (!existsSync(f)) return [];
    // message lines only: these fixtures have no live pane, so each send also logs a trigger-refused line (T63e2)
    return readFileSync(f, 'utf-8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l)).filter((e) => e.type === 'message');
}

test('send-message requires team_name', async () => {
    await assert.rejects(
        () => runApiSendMessage({ from_worker: 'alice', to_worker: 'bob', body: 'hi' }),
        /team_name is required/
    );
});

test('send-message requires from_worker', async () => {
    await assert.rejects(
        () => runApiSendMessage({ team_name: 't1', to_worker: 'bob', body: 'hi' }),
        /from_worker is required/
    );
});

test('send-message requires to_worker', async () => {
    await assert.rejects(
        () => runApiSendMessage({ team_name: 't1', from_worker: 'alice', body: 'hi' }),
        /to_worker is required/
    );
});

test('send-message requires body', async () => {
    await assert.rejects(
        () => runApiSendMessage({ team_name: 't1', from_worker: 'alice', to_worker: 'bob' }),
        /body is required/
    );
});

test('send-message rejects non-boolean expects_reply', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
                body: 'hi', expects_reply: 'yes',
            }),
            /expects_reply must be a boolean/
        );
    } finally {
        cleanup(ctx);
    }
});

test('send-message drops a message into recipient spool, recipient mailbox untouched', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', body: 'hello',
        });
        assert.equal(result.ok, true);
        assert.equal(result.delivered_to, 'bob');

        const spool = readSpoolFiles(ctx, 'bob');
        assert.equal(spool.length, 1);
        assert.equal(spool[0].message_id, result.message_id);
        assert.equal(spool[0].body, 'hello');
        assert.equal(spool[0].from_worker, 'alice');
        assert.equal(spool[0].to_worker, 'bob');

        // Recipient mailbox file should NOT exist yet — it's owned by the worker
        // and gets touched only on mailbox-list (spool absorption).
        const mboxPath = join(ctx.stateRoot, 'mailbox', 'bob.json');
        assert.equal(existsSync(mboxPath), false);
    } finally {
        cleanup(ctx);
    }
});

test('send-message defaults reply_to=null and expects_reply=false', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', body: 'hello',
        });
        assert.equal(result.reply_to, null);
        assert.equal(result.expects_reply, false);
        const spool = readSpoolFiles(ctx, 'bob');
        assert.equal(spool[0].reply_to, null);
        assert.equal(spool[0].expects_reply, false);
    } finally {
        cleanup(ctx);
    }
});

test('send-message preserves reply_to when provided', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'bob', to_worker: 'alice',
            body: 'here is the answer', reply_to: 'orig-msg-123',
        });
        assert.equal(result.reply_to, 'orig-msg-123');
        const spool = readSpoolFiles(ctx, 'alice');
        assert.equal(spool[0].reply_to, 'orig-msg-123');
    } finally {
        cleanup(ctx);
    }
});

test('send-message records direction=out in sender archive', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', body: 'hi',
        });
        const archive = readArchiveLines(ctx, 'alice');
        assert.equal(archive.length, 1);
        assert.equal(archive[0].direction, 'out');
        assert.equal(archive[0].message_id, result.message_id);
        assert.equal(archive[0].to_worker, 'bob');
        // Recipient archive is empty until they call mark-delivered.
        assert.deepEqual(readArchiveLines(ctx, 'bob'), []);
    } finally {
        cleanup(ctx);
    }
});

test('send-message with expects_reply=true populates sender sent_pending', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: '주문 상태 enum 알려줘', expects_reply: true,
        });
        assert.equal(result.expects_reply, true);
        const mbox = readMailbox(ctx, 'alice');
        const pending = mbox.sent_pending[result.message_id];
        assert.ok(pending, 'sent_pending entry exists');
        assert.equal(pending.to_worker, 'bob');
        assert.equal(pending.expects_reply, true);
        assert.equal(typeof pending.sent_at, 'string');
    } finally {
        cleanup(ctx);
    }
});

test('send-message with expects_reply=false does NOT populate sent_pending', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: '작업 완료', expects_reply: false,
        });
        // sender mailbox should either not exist or have empty sent_pending.
        const mboxPath = join(ctx.stateRoot, 'mailbox', 'alice.json');
        if (existsSync(mboxPath)) {
            const mbox = readMailbox(ctx, 'alice');
            assert.equal(mbox.sent_pending[result.message_id], undefined);
        }
    } finally {
        cleanup(ctx);
    }
});

test('send-message returns a hint when body contains "?" but expects_reply is omitted', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: '주문 상태 enum 알려줘?',
        });
        assert.equal(result.expects_reply, false);
        assert.ok(typeof result.hint === 'string' && result.hint.includes('expects_reply'),
            `hint should mention expects_reply: ${result.hint}`);
    } finally {
        cleanup(ctx);
    }
});

test('send-message omits hint when expects_reply was explicitly provided', async () => {
    const ctx = setupTeam();
    try {
        const r1 = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: '주문 상태 enum 알려줘?', expects_reply: true,
        });
        assert.equal(r1.hint, undefined);
        const r2 = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: '진짜 별일 없지?', expects_reply: false,
        });
        assert.equal(r2.hint, undefined);
    } finally {
        cleanup(ctx);
    }
});

test('send-message rejects self-message with expects_reply=true', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: ctx.teamName, from_worker: 'alice', to_worker: 'alice',
                body: '나에게 메모', expects_reply: true,
            }),
            /Self-message with expects_reply=true is not supported/
        );
    } finally {
        cleanup(ctx);
    }
});

test('send-message allows self-message when expects_reply is false (memo)', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'alice', body: '나에게 메모',
        });
        assert.equal(result.ok, true);
        // Self-memo lands in alice's own spool.
        const spool = readSpoolFiles(ctx, 'alice');
        assert.equal(spool.length, 1);
    } finally {
        cleanup(ctx);
    }
});

test('send-message rejects from_worker made entirely of disallowed characters', async () => {
    await assert.rejects(
        () => runApiSendMessage({
            team_name: 't1', from_worker: '../', to_worker: 'bob', body: 'hi',
        }),
        /no valid characters/
    );
});

test('send-message rejects unknown recipient', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: ctx.teamName, from_worker: 'alice', to_worker: 'ghost', body: 'hi',
            }),
            /not in team/
        );
    } finally {
        cleanup(ctx);
    }
});

test('send-message rejects unknown sender (guards against hallucinated from_worker)', async () => {
    const ctx = setupTeam(); // roster is alice + bob; "ghost" is not a worker
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: ctx.teamName, from_worker: 'ghost', to_worker: 'bob', body: 'hi',
            }),
            /Sender 'ghost' not in team/
        );
    } finally {
        cleanup(ctx);
    }
});

test('events.jsonl carries message_id, reply_to, expects_reply', async () => {
    const ctx = setupTeam();
    try {
        const r1 = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: 'q', expects_reply: true,
        });
        const r2 = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'bob', to_worker: 'alice',
            body: 'a', reply_to: r1.message_id,
        });
        const events = readEvents(ctx);
        assert.equal(events.length, 2);
        assert.equal(events[0].message_id, r1.message_id);
        assert.equal(events[0].expects_reply, true);
        assert.equal(events[0].reply_to, null);
        assert.equal(events[1].message_id, r2.message_id);
        assert.equal(events[1].reply_to, r1.message_id);
        assert.equal(events[1].expects_reply, false);
    } finally {
        cleanup(ctx);
    }
});
