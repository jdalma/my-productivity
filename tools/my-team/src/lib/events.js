/**
 * Append-only event log for worker-to-worker messages.
 *
 * Written by send-message API; read by `my-team monitor` and post-hoc
 * analysis tools (jq, grep over events.jsonl).
 *
 * Schema v2 (Phase B):
 *   { ts, type: "message", from, to, body,
 *     message_id, reply_to, expects_reply }
 *
 * The events log is the canonical timeline SSOT — it preserves the order
 * across the whole team, while per-worker mailbox + archive files hold the
 * worker-local active/consumed state.
 *
 * Failures are swallowed (try/catch + stderr warn) so mailbox writes are
 * never blocked by event log failures.
 */

import { appendFile, mkdir } from 'fs/promises';
import { dirname, join } from 'path';

export function eventsLogPath(stateRoot) {
    return join(stateRoot, 'events.jsonl');
}

export async function appendMessageEvent(stateRoot, event) {
    const { from, to, body, message_id, reply_to, expects_reply, ...extra } = event;
    const entry = {
        ts: new Date().toISOString(),
        type: 'message',
        from,
        to,
        body,
        message_id: message_id ?? null,
        reply_to: reply_to ?? null,
        expects_reply: Boolean(expects_reply),
        // Cross-team sends add from_team / to_team.
        // Kept open rather than whitelisted so the timeline records which teams
        // a message crossed — a same-team send passes none of these and its
        // event shape is unchanged.
        ...extra,
    };
    await writeEvent(stateRoot, entry);
}

/** One event of another `type` (the tmux shim's refusals, T56), stamped with `ts` like a message. */
export async function appendEvent(stateRoot, { type, ...fields }) {
    await writeEvent(stateRoot, { ts: new Date().toISOString(), type, ...fields });
}

async function writeEvent(stateRoot, entry) {
    const line = JSON.stringify(entry) + '\n';
    const path = eventsLogPath(stateRoot);
    try {
        await mkdir(dirname(path), { recursive: true });
        await appendFile(path, line, 'utf-8');
    } catch (err) {
        process.stderr.write(`[my-team] events.jsonl append failed: ${err.message}\n`);
    }
}
