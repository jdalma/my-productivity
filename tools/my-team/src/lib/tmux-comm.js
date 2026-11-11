/**
 * Adapted from oh-my-claude-sisyphus (MIT License)
 * https://github.com/Yeachan-Heo/oh-my-claudecode
 *
 * Source: dist/team/tmux-comm.js (low-level functions only)
 *
 * Schema v2 (Phase B — incoming-spool + sent_pending):
 *
 *   mailbox/<worker>.json   ← worker-owned (worker is sole writer)
 *     {
 *       "schema_version": 2,
 *       "worker": <name>,
 *       "inbox":        { [message_id]: { from_worker, body, reply_to,
 *                                          expects_reply, created_at,
 *                                          notified_at?, consumed_at? } },
 *       "sent_pending": { [message_id]: { to_worker, body, expects_reply,
 *                                          sent_at } }
 *     }
 *
 *   incoming-spool/<to_worker>/<message_id>.json   ← sender writes, receiver consumes
 *     {
 *       "message_id", "from_worker", "to_worker", "body",
 *       "reply_to", "expects_reply", "created_at"
 *     }
 *
 *   archive/<worker>.jsonl  ← worker-owned append-only
 *     One JSON object per line. direction "out" on send, "in" on
 *     mark-delivered.
 *
 * Concurrency model:
 *   - Each mailbox.json has exactly ONE writer (the owning worker / its
 *     mailbox-list and mark-delivered handlers running in the worker's
 *     process). Senders never touch the recipient mailbox file.
 *   - incoming-spool uses one file per message, so concurrent senders cannot
 *     clobber each other (filename uniqueness via random message_id).
 *   - archive jsonl is append-only.
 *   - mailbox.json writes use atomicWriteJson (write-temp + rename) so torn
 *     writes are impossible.
 */

import { existsSync, unlinkSync, rmSync } from 'fs';
import { mkdir, readFile, readdir, unlink } from 'fs/promises';
import { join, dirname } from 'path';

import { sendToWorker } from './tmux-session.js';
import { tmuxExecAsync } from './tmux-utils.js';
import { TeamPaths, absPath } from './state-paths.js';
import { atomicWriteJson, appendFileWithMode, ensureDirWithMode } from './fs-utils.js';
import { appendEvent } from './events.js';

export const MAILBOX_SCHEMA_VERSION = 2;

function mailboxPath(teamName, workerName, cwd) {
    return absPath(cwd, TeamPaths.mailbox(teamName, workerName));
}

function archivePath(teamName, workerName, cwd) {
    return absPath(cwd, TeamPaths.archive(teamName, workerName));
}

function spoolDir(teamName, workerName, cwd) {
    return absPath(cwd, TeamPaths.incomingSpoolDir(teamName, workerName));
}

function spoolFile(teamName, workerName, messageId, cwd) {
    return absPath(cwd, TeamPaths.incomingSpoolFile(teamName, workerName, messageId));
}

function emptyMailbox(workerName) {
    return {
        schema_version: MAILBOX_SCHEMA_VERSION,
        worker: workerName,
        inbox: {},
        sent_pending: {},
    };
}

/**
 * Read a mailbox file. Returns the v2 shape. Missing file → empty mailbox.
 * Schema mismatch → throw (no automatic migration; operator must shutdown).
 */
export async function readMailboxFile(teamName, workerName, cwd) {
    const canonicalPath = mailboxPath(teamName, workerName, cwd);
    let raw;
    try {
        raw = await readFile(canonicalPath, 'utf-8');
    } catch {
        return emptyMailbox(workerName);
    }
    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (err) {
        throw new Error(`Mailbox at ${canonicalPath} is not valid JSON: ${err.message}`);
    }
    if (!parsed || typeof parsed !== 'object') {
        return emptyMailbox(workerName);
    }
    if (parsed.schema_version !== MAILBOX_SCHEMA_VERSION) {
        throw new Error(
            `Mailbox at ${canonicalPath} has schema_version=${parsed.schema_version ?? 'missing'}, ` +
            `expected ${MAILBOX_SCHEMA_VERSION}. ` +
            `Shutdown the team (my-team shutdown) and restart to begin with a fresh schema; ` +
            `automatic migration is not supported.`
        );
    }
    return {
        schema_version: MAILBOX_SCHEMA_VERSION,
        worker: parsed.worker ?? workerName,
        inbox: parsed.inbox && typeof parsed.inbox === 'object' ? parsed.inbox : {},
        sent_pending: parsed.sent_pending && typeof parsed.sent_pending === 'object' ? parsed.sent_pending : {},
    };
}

export async function writeMailboxFile(teamName, workerName, cwd, mailbox) {
    const canonicalPath = mailboxPath(teamName, workerName, cwd);
    await mkdir(join(canonicalPath, '..'), { recursive: true });
    atomicWriteJson(canonicalPath, {
        schema_version: MAILBOX_SCHEMA_VERSION,
        worker: workerName,
        inbox: mailbox.inbox ?? {},
        sent_pending: mailbox.sent_pending ?? {},
    });
}

/**
 * Append one entry to a worker's archive jsonl. Race-free: append-only.
 * `direction` is "in" (received and consumed) or "out" (sent).
 */
export function appendArchive(teamName, workerName, cwd, entry) {
    const path = archivePath(teamName, workerName, cwd);
    ensureDirWithMode(dirname(path));
    appendFileWithMode(path, JSON.stringify(entry) + '\n');
}

/**
 * Drop a message into the recipient's incoming-spool. One file per message,
 * so concurrent senders never collide.
 */
function dropSpoolMessage(teamName, toWorker, cwd, message, recipientStateRoot) {
    // `recipientStateRoot` bypasses TeamPaths entirely and is REQUIRED for
    // cross-team delivery: TeamPaths.root() honours the MY_TEAM_STATE_ROOT env
    // var ahead of its teamName argument, and every worker process has that var
    // pinned to its OWN team. Composing the recipient path through TeamPaths
    // would therefore write into the SENDER's directory — where the recipient
    // never looks — and the send would report success. Passing the recipient's
    // state root (read from its own manifest) is the only correct addressing.
    const path = recipientStateRoot
        ? join(recipientStateRoot, 'incoming-spool', toWorker, `${message.message_id}.json`)
        : spoolFile(teamName, toWorker, message.message_id, cwd);
    ensureDirWithMode(dirname(path));
    atomicWriteJson(path, message);
}

/**
 * Absorb all messages from a worker's incoming-spool into its mailbox.inbox.
 * Each spool file is deleted after its contents are merged. Resolves
 * sent_pending entries when an absorbed message carries a known reply_to.
 *
 * Returns the list of absorbed message_ids (for logging / debugging).
 */
export async function absorbIncomingSpool(teamName, workerName, cwd) {
    const dir = spoolDir(teamName, workerName, cwd);
    let entries;
    try {
        entries = await readdir(dir);
    } catch (err) {
        if (err && err.code === 'ENOENT') return [];
        throw err;
    }
    const jsonFiles = entries.filter((n) => n.endsWith('.json'));
    if (jsonFiles.length === 0) return [];

    const mailbox = await readMailboxFile(teamName, workerName, cwd);
    const absorbed = [];
    for (const filename of jsonFiles) {
        const filePath = join(dir, filename);
        let payload;
        try {
            payload = JSON.parse(await readFile(filePath, 'utf-8'));
        } catch (err) {
            process.stderr.write(`[tmux-comm] dropping malformed spool file ${filePath}: ${err.message}\n`);
            try { await unlink(filePath); } catch { /* ignore */ }
            continue;
        }
        if (!payload || !payload.message_id) {
            try { await unlink(filePath); } catch { /* ignore */ }
            continue;
        }
        mailbox.inbox[payload.message_id] = {
            message_id: payload.message_id,
            from_worker: payload.from_worker,
            to_worker: payload.to_worker ?? workerName,
            body: payload.body,
            reply_to: payload.reply_to ?? null,
            expects_reply: Boolean(payload.expects_reply),
            created_at: payload.created_at,
            // Cross-team origin. Must survive absorption: a reply without
            // `to_team` would be addressed inside the recipient's own team and
            // never reach the asker.
            ...(payload.from_team ? { from_team: payload.from_team } : {}),
        };
        if (payload.reply_to && mailbox.sent_pending[payload.reply_to]) {
            // A peer answered a question I had pending — resolve it.
            delete mailbox.sent_pending[payload.reply_to];
        }
        absorbed.push(payload.message_id);
        try { await unlink(filePath); } catch { /* ignore */ }
    }
    if (absorbed.length > 0) {
        await writeMailboxFile(teamName, workerName, cwd, mailbox);
    }
    return absorbed;
}

/**
 * Whether `paneId` is, right now, `owner.worker`'s pane in `owner.session` (T63e1, R70 R1): the same
 * (session, @worker_name) test as team liveness. Pane ids are server-wide and reused, so a stale manifest
 * (a stopped team, a restarted tmux) can name another team's pane; in a split-pane team the session is the
 * user's, and @worker_name tells the team's panes apart. `reason` says why not, or why it could not tell.
 */
async function paneOwnedBy(paneId, owner) {
    const session = owner?.session?.split(':')[0];
    if (!paneId || !session || !owner?.worker) return { ok: false, reason: 'no pane id or session in the manifest to check against' };
    let stdout;
    try {
        // worker first and '|' between: a worker name has no '|', and tmux may print a tab as '_' (no UTF-8 locale)
        ({ stdout } = await tmuxExecAsync(['display-message', '-p', '-t', paneId, '#{@worker_name}|#{session_name}']));
    } catch {
        return { ok: false, reason: `pane ${paneId} is gone or tmux cannot say` };
    }
    const line = stdout.replace(/\n$/, '');
    const cut = line.indexOf('|');
    const paneWorker = line.slice(0, cut), paneSession = line.slice(cut + 1);
    if (paneSession !== session || paneWorker.trim() !== owner.worker) {
        return { ok: false, reason: `pane ${paneId} is not ${owner.worker}'s in ${session} now` };
    }
    return { ok: true };
}

/**
 * Send a short tmux trigger to a worker pane, only while the pane is still `owner`'s
 * ({session, worker}, see paneOwnedBy). Message MUST be < 200 chars. Never throws. Returns {sent}; when the
 * ownership check refused it, also `refused` (the reason). An unanswered prompt or a busy pane is
 * `sent: false` without `refused`: the recipient's next poll picks the message up.
 */
export async function sendTmuxTrigger(paneId, triggerType, payload, owner) {
    const message = payload ? `${triggerType}:${payload}` : triggerType;
    if (message.length > 200) {
        console.warn(`[tmux-comm] sendTmuxTrigger: message rejected (${message.length} chars exceeds 200 char limit)`);
        return { sent: false };
    }
    const check = await paneOwnedBy(paneId, owner);
    if (!check.ok) return { sent: false, refused: check.reason };
    try {
        return { sent: await sendToWorker('', paneId, message) };
    } catch {
        return { sent: false };
    }
}

function newMessageId() {
    return `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

/**
 * Send a direct message from one worker to another.
 *
 * Owner model:
 *   - Sender writes ONLY: the sender's own mailbox.sent_pending (when
 *     expects_reply), the sender's own archive jsonl, and the recipient's
 *     incoming-spool file.
 *   - The recipient absorbs the spool file into its own inbox on its next
 *     mailbox-list call.
 *
 * Step ordering (crash-safe):
 *   1. Record `sent_pending` on the sender first (only when expectsReply).
 *      A crash before this step means nothing happened. A crash after it
 *      means the sender shows a pending entry for a message the recipient
 *      will never get — visible to the user and easy to recover.
 *   2. Append the sender archive line (direction=out). Now the message
 *      exists in the durable sender log even if delivery fails next.
 *   3. Drop the spool file. This is the act of delivery.
 *   4. Fire the tmux notification (best-effort; recipient still polls).
 *
 * `replyTo` (optional) is the message_id this answers. `expectsReply`
 * defaults to false; senders set it to true only for questions. `session` is
 * the recipient team's tmux session (manifest session_name): the trigger is
 * typed only while toPaneId is still the recipient's pane there. The returned
 * message carries `trigger` ({sent, refused?}).
 */
export async function queueDirectMessage(
    teamName,
    fromWorker,
    toWorker,
    body,
    toPaneId,
    cwd,
    replyTo = null,
    expectsReply = false,
    crossTeam = null,
    session = null
) {
    const messageId = newMessageId();
    const createdAt = new Date().toISOString();
    const message = {
        message_id: messageId,
        from_worker: fromWorker,
        to_worker: toWorker,
        body,
        reply_to: replyTo ?? null,
        expects_reply: Boolean(expectsReply),
        created_at: createdAt,
        // Cross-team only. `from_team` is what lets the recipient reply back
        // with `to_team`; without it a reply would be addressed within the
        // recipient's own team and never reach the asker.
        ...(crossTeam ? { from_team: teamName, to_team: crossTeam.toTeam } : {}),
    };

    // 1. If we expect a reply, track it on our own sent_pending FIRST so a
    //    later failure cannot leave the recipient with a message that the
    //    sender doesn't know it sent.
    if (expectsReply) {
        const senderMailbox = await readMailboxFile(teamName, fromWorker, cwd);
        senderMailbox.sent_pending[messageId] = {
            message_id: messageId,
            to_worker: toWorker,
            body,
            expects_reply: true,
            sent_at: createdAt,
        };
        await writeMailboxFile(teamName, fromWorker, cwd, senderMailbox);
    }

    // 2. Sender archive (direction=out) — durable record before delivery.
    appendArchive(teamName, fromWorker, cwd, { ...message, direction: 'out' });

    // 3. Drop into recipient's spool (commits delivery).
    dropSpoolMessage(teamName, toWorker, cwd, message, crossTeam?.toStateRoot);

    // 4. Notify the recipient via tmux (best-effort, and only into its own pane).
    const trigger = await sendTmuxTrigger(toPaneId, 'new-message', fromWorker, { session, worker: toWorker });
    if (trigger.refused) {
        // the recipient wakes only on a trigger: put the refusal on its team's timeline, for monitor and the user
        const root = crossTeam?.toStateRoot ?? absPath(cwd, TeamPaths.root(teamName));
        try {
            await appendEvent(root, { type: 'trigger-refused', team: teamName, worker: fromWorker, to: toWorker, pane: toPaneId ?? null, reason: trigger.refused });
        } catch { /* the message is delivered; the caller warns about the trigger */ }
    }

    return { ...message, trigger };
}

/**
 * Cleanup per-cwd worker state for `my-team shutdown`:
 *   - mailbox/<worker>.json
 *   - archive/<worker>.jsonl
 *   - incoming-spool/<worker>/  (and every file inside it)
 *
 * Keeps the operator-visible audit trail (the team-state root jsonl events
 * log) intact. Failures are swallowed — cleanup is best-effort.
 */
export function cleanupWorkerCwdState(teamName, workerName, cwd) {
    if (!cwd) return;
    const targets = [
        mailboxPath(teamName, workerName, cwd),
        archivePath(teamName, workerName, cwd),
    ];
    for (const f of targets) {
        if (existsSync(f)) {
            try { unlinkSync(f); } catch { /* ignore */ }
        }
    }
    const dir = spoolDir(teamName, workerName, cwd);
    if (existsSync(dir)) {
        try { rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
    }
}

/**
 * Read all messages from a worker mailbox. Returned messages are sorted by
 * created_at ascending — callers must not rely on object key order.
 */
export async function readMailbox(teamName, workerName, cwd) {
    const mailbox = await readMailboxFile(teamName, workerName, cwd);
    const entries = Object.values(mailbox.inbox);
    entries.sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
    return entries.map((m) => ({
        id: m.message_id,
        from: m.from_worker,
        body: m.body,
        createdAt: m.created_at,
        notifiedAt: m.notified_at,
    }));
}
