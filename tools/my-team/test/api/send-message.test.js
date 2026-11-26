/**
 * Unit tests for `my-team api send-message` (schema v3: kind, T54).
 *
 * Owner model:
 *   - Sender writes the recipient's incoming-spool file, the sender's own
 *     mailbox.sent_pending (when the kind awaits an answer), and the sender's own
 *     archive jsonl (direction: out).
 *   - The recipient mailbox.json is NOT touched on send — that happens when
 *     the recipient calls mailbox-list (spool→inbox absorption).
 *
 * kind (required): question | answer | blocked | notice | closeout | team-handoff | team-takeover
 * (board is the board's own); events.jsonl lines carry message_id / reply_to / kind.
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
        () => runApiSendMessage({ kind: 'notice', from_worker: 'alice', to_worker: 'bob', body: 'hi' }),
        /team_name is required/
    );
});

test('send-message requires from_worker', async () => {
    await assert.rejects(
        () => runApiSendMessage({ kind: 'notice', team_name: 't1', to_worker: 'bob', body: 'hi' }),
        /from_worker is required/
    );
});

test('send-message requires to_worker', async () => {
    await assert.rejects(
        () => runApiSendMessage({ kind: 'notice', team_name: 't1', from_worker: 'alice', body: 'hi' }),
        /to_worker is required/
    );
});

test('send-message requires body', async () => {
    await assert.rejects(
        () => runApiSendMessage({ kind: 'notice', team_name: 't1', from_worker: 'alice', to_worker: 'bob' }),
        /body is required/
    );
});

test('send-message refuses expects_reply: kind replaced it (T54)', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind: 'question',
                body: 'hi', expects_reply: true,
            }),
            /expects_reply was removed; a question is kind "question"/
        );
    } finally {
        cleanup(ctx);
    }
});

test('a missing, unknown or board kind is refused with the kinds a sender may use', async () => {
    const ctx = setupTeam();
    const send = (extra) => runApiSendMessage({ team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', body: 'hi', ...extra });
    const kinds = /kind is one of: question, answer, blocked, notice, closeout, team-handoff, team-takeover$/;
    try {
        await assert.rejects(() => send({}), (e) => /^kind is required;/.test(e.message) && kinds.test(e.message));
        await assert.rejects(() => send({ kind: 'ask' }), (e) => /^unknown kind "ask";/.test(e.message) && kinds.test(e.message));
        await assert.rejects(() => send({ kind: 'board' }), /board is sent by the board only;/);
        assert.deepEqual(readSpoolFiles(ctx, 'bob'), []);
    } finally {
        cleanup(ctx);
    }
});

test('an answer needs reply_to', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({ team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind: 'answer', body: 'yes' }),
            /an answer needs reply_to/
        );
    } finally {
        cleanup(ctx);
    }
});

test('blocked carries task, need and the board refusal; without task or need it is refused', async () => {
    const ctx = setupTeam();
    const send = (extra) => runApiSendMessage({ team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind: 'blocked', body: 'stuck', ...extra });
    try {
        await assert.rejects(() => send({ need: 'x' }), /blocked needs task/);
        await assert.rejects(() => send({ task: 'T1' }), /blocked needs need/);
        await assert.rejects(() => send({ task: 'T1', need: 'x', board_error: 'refused' }), /board_error is \{code, message\}/);
        const r = await send({ task: 'T1', need: 'pm to mark it a document', board_error: { code: 'no-commit', message: 'a landing needs a commit', extra: 1 } });
        const [m] = readSpoolFiles(ctx, 'bob');
        assert.equal(m.message_id, r.message_id);
        assert.equal(m.kind, 'blocked');
        assert.equal(m.task, 'T1');
        assert.equal(m.need, 'pm to mark it a document');
        assert.deepEqual(m.board_error, { code: 'no-commit', message: 'a landing needs a commit' });
        assert.equal(readMailbox(ctx, 'alice').sent_pending[r.message_id], undefined);   // blocked waits for nothing
    } finally {
        cleanup(ctx);
    }
});

test('task, need and board_error belong to blocked only', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({ team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind: 'notice', body: 'hi', task: 'T1' }),
            /task, need and board_error belong to kind blocked/
        );
    } finally {
        cleanup(ctx);
    }
});

test('send-message drops a message into recipient spool, recipient mailbox untouched', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({ kind: 'notice',
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

test('send-message writes the kind and defaults reply_to=null', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({ kind: 'notice',
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', body: 'hello',
        });
        assert.equal(result.reply_to, null);
        assert.equal(result.kind, 'notice');
        const spool = readSpoolFiles(ctx, 'bob');
        assert.equal(spool[0].reply_to, null);
        assert.equal(spool[0].kind, 'notice');
        assert.equal('expects_reply' in spool[0], false);
    } finally {
        cleanup(ctx);
    }
});

test('send-message preserves reply_to when provided', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({ kind: 'answer',
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
        const result = await runApiSendMessage({ kind: 'notice',
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

test('a question, a closeout and a team-handoff wait in the sender sent_pending', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: '주문 상태 enum 알려줘', kind: 'question',
        });
        assert.equal(result.kind, 'question');
        const others = [];
        for (const kind of ['closeout', 'team-handoff']) {
            others.push(await runApiSendMessage({ team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind, body: kind }));
        }
        const mbox = readMailbox(ctx, 'alice');
        const pending = mbox.sent_pending[result.message_id];
        assert.ok(pending, 'sent_pending entry exists');
        assert.equal(pending.to_worker, 'bob');
        assert.equal(pending.kind, 'question');
        assert.equal(typeof pending.sent_at, 'string');
        assert.deepEqual(others.map((o) => mbox.sent_pending[o.message_id]?.kind), ['closeout', 'team-handoff']);
    } finally {
        cleanup(ctx);
    }
});

test('notice, answer and team-takeover do NOT populate sent_pending', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: '작업 완료', kind: 'notice',
        });
        await runApiSendMessage({ team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind: 'answer', reply_to: 'x', body: 'a' });
        await runApiSendMessage({ team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind: 'team-takeover', body: 'b' });
        // sender mailbox should either not exist or have empty sent_pending.
        const mboxPath = join(ctx.stateRoot, 'mailbox', 'alice.json');
        if (existsSync(mboxPath)) {
            const mbox = readMailbox(ctx, 'alice');
            assert.deepEqual(mbox.sent_pending, {});
        }
        assert.equal(result.kind, 'notice');
    } finally {
        cleanup(ctx);
    }
});

test('a "?" in a notice is just text: no hint (T54 removed the guess)', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob', kind: 'notice',
            body: '주문 상태 enum 알려줘?',
        });
        assert.equal(result.hint, undefined);
    } finally {
        cleanup(ctx);
    }
});

test('send-message rejects a self-question', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({
                team_name: ctx.teamName, from_worker: 'alice', to_worker: 'alice',
                body: '나에게 메모', kind: 'question',
            }),
            /Self-message of kind question is not supported/
        );
    } finally {
        cleanup(ctx);
    }
});

test('send-message allows a self-notice (memo)', async () => {
    const ctx = setupTeam();
    try {
        const result = await runApiSendMessage({ kind: 'notice',
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
        () => runApiSendMessage({ kind: 'notice',
            team_name: 't1', from_worker: '../', to_worker: 'bob', body: 'hi',
        }),
        /no valid characters/
    );
});

test('send-message rejects unknown recipient', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runApiSendMessage({ kind: 'notice',
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
            () => runApiSendMessage({ kind: 'notice',
                team_name: ctx.teamName, from_worker: 'ghost', to_worker: 'bob', body: 'hi',
            }),
            /Sender 'ghost' not in team/
        );
    } finally {
        cleanup(ctx);
    }
});

test('events.jsonl carries message_id, reply_to, kind', async () => {
    const ctx = setupTeam();
    try {
        const r1 = await runApiSendMessage({
            team_name: ctx.teamName, from_worker: 'alice', to_worker: 'bob',
            body: 'q', kind: 'question',
        });
        const r2 = await runApiSendMessage({ kind: 'answer',
            team_name: ctx.teamName, from_worker: 'bob', to_worker: 'alice',
            body: 'a', reply_to: r1.message_id,
        });
        const events = readEvents(ctx);
        assert.equal(events.length, 2);
        assert.equal(events[0].message_id, r1.message_id);
        assert.equal(events[0].kind, 'question');
        assert.equal(events[0].reply_to, null);
        assert.equal(events[1].message_id, r2.message_id);
        assert.equal(events[1].reply_to, r1.message_id);
        assert.equal(events[1].kind, 'answer');
    } finally {
        cleanup(ctx);
    }
});
