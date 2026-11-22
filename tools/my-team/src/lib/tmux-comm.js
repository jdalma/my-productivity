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
 *   - Several processes write one mailbox.json: the owner's mailbox-list
 *     (spool absorption) and mark-delivered, and its own sends that record
 *     sent_pending. Parallel tool calls run them at once, so every
 *     read-modify-write goes through updateMailbox / withMailboxLock, which
 *     holds `<mailbox>.lock` (a token file hard-linked into place) for the
 *     whole cycle.
 *     Senders never touch the recipient mailbox file.
 *   - incoming-spool uses one file per message, so concurrent senders cannot
 *     clobber each other (filename uniqueness via random message_id).
 *   - archive jsonl is append-only.
 *   - mailbox.json writes use atomicWriteJson (write-temp + rename) so torn
 *     writes are impossible.
 */

import { existsSync, unlinkSync, rmSync, readFileSync, readdirSync, writeFileSync, linkSync } from 'fs';
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
    return readMailboxAt(mailboxPath(teamName, workerName, cwd), workerName);
}

function readMailboxAt(canonicalPath, workerName) {
    let raw;
    try {
        raw = readFileSync(canonicalPath, 'utf-8');
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

function writeMailboxAt(canonicalPath, workerName, mailbox) {
    atomicWriteJson(canonicalPath, {
        schema_version: MAILBOX_SCHEMA_VERSION,
        worker: workerName,
        inbox: mailbox.inbox ?? {},
        sent_pending: mailbox.sent_pending ?? {},
    });
}

const LOCK_WAIT_MS = 10_000;
const sleepCell = new Int32Array(new SharedArrayBuffer(4));

function readLock(lockPath) {
    try {
        return readFileSync(lockPath, 'utf-8');
    } catch (err) {
        if (err.code === 'ENOENT') return null;
        throw err;
    }
}

function pidAlive(pid) {
    if (!Number.isInteger(pid) || pid <= 0) return false;
    try {
        process.kill(pid, 0);
        return true;
    } catch (err) {
        return err.code !== 'ESRCH';
    }
}

// ponytail: content is re-read right before unlink, so a lock replaced in the microseconds between the
// read and the unlink can still be removed; close that with a rename-based or flock lock if it ever bites.
function unlinkIfContent(lockPath, content) {
    if (readLock(lockPath) === content) rmSync(lockPath, { force: true });
}

/**
 * Run `fn` while holding `<mailboxFile>.lock`, whose content is a token unique to this call.
 * Synchronous on purpose: no critical section spans an await, so two calls in one process can
 * never deadlock on each other. Only a lock whose holder pid is dead is taken over; a live holder,
 * however slow, keeps it and the waiter throws after the wait (MY_TEAM_MAILBOX_LOCK_WAIT_MS).
 */
function withMailboxLock(mailboxFile, fn) {
    const lockPath = `${mailboxFile}.lock`;
    ensureDirWithMode(dirname(lockPath));
    const token = `${process.pid}:${Math.random().toString(36).slice(2)}`;
    const waitMs = Number.parseInt(process.env.MY_TEAM_MAILBOX_LOCK_WAIT_MS ?? '', 10) || LOCK_WAIT_MS;
    const deadline = Date.now() + waitMs;
    // The token is written to a private file first and linked into place, so the lock path never
    // exists without its token: a crash between create and write cannot leave an empty lock.
    const tokenFile = `${lockPath}.${token.replace(':', '-')}`;
    writeFileSync(tokenFile, token, { mode: 0o600 });
    for (;;) {
        try {
            linkSync(tokenFile, lockPath);
            rmSync(tokenFile, { force: true });
            break;
        } catch (err) {
            if (err.code !== 'EEXIST') {
                rmSync(tokenFile, { force: true });
                throw err;
            }
            const held = readLock(lockPath);
            if (held === null) continue;
            const pid = Number.parseInt(held, 10);
            if (!pidAlive(pid)) {
                unlinkIfContent(lockPath, held);
                continue;
            }
            if (Date.now() > deadline) {
                rmSync(tokenFile, { force: true });
                throw new Error(`mailbox lock ${lockPath} still held by live pid ${pid} after ${waitMs}ms`);
            }
            Atomics.wait(sleepCell, 0, 0, 5);
        }
    }
    try {
        return fn();
    } finally {
        unlinkIfContent(lockPath, token);
    }
}

/**
 * Locked read-modify-write of one worker's mailbox. `mutate` edits the
 * mailbox in place and must be synchronous; its return value is returned.
 * A throw from `mutate` skips the write.
 */
export function updateMailbox(teamName, workerName, cwd, mutate) {
    const canonicalPath = mailboxPath(teamName, workerName, cwd);
    return withMailboxLock(canonicalPath, () => {
        const mailbox = readMailboxAt(canonicalPath, workerName);
        const result = mutate(mailbox);
        writeMailboxAt(canonicalPath, workerName, mailbox);
        return result;
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
 * Spool files are deleted only after the mailbox write succeeds, so a crash or
 * a failed write leaves them for the next call; re-absorbing is idempotent
 * because inbox is keyed by message_id. Resolves
 * sent_pending entries when an absorbed message carries a known reply_to.
 *
 * Returns the list of absorbed message_ids (for logging / debugging).
 */
export async function absorbIncomingSpool(teamName, workerName, cwd) {
    const dir = spoolDir(teamName, workerName, cwd);
    let entries;
    try {
        entries = readdirSync(dir);
    } catch (err) {
        if (err && err.code === 'ENOENT') return [];
        throw err;
    }
    if (!entries.some((n) => n.endsWith('.json'))) return [];

    const canonicalPath = mailboxPath(teamName, workerName, cwd);
    // The unlink stays inside the lock: unlinked after release, a spool file another absorber
    // still sees would come back into the inbox after mark-delivered removed it.
    return withMailboxLock(canonicalPath, () => absorbLocked(dir, canonicalPath, workerName));
}

function absorbLocked(dir, canonicalPath, workerName) {
    // Re-list under the lock: a concurrent absorber may have consumed files since the first look.
    const jsonFiles = readdirSync(dir).filter((n) => n.endsWith('.json'));
    const mailbox = readMailboxAt(canonicalPath, workerName);
    const absorbed = [];
    const absorbedFiles = [];
    for (const filename of jsonFiles) {
        const filePath = join(dir, filename);
        let payload;
        try {
            payload = JSON.parse(readFileSync(filePath, 'utf-8'));
        } catch (err) {
            process.stderr.write(`[tmux-comm] dropping malformed spool file ${filePath}: ${err.message}\n`);
            try { unlinkSync(filePath); } catch { /* ignore */ }
            continue;
        }
        if (!payload || !payload.message_id) {
            try { unlinkSync(filePath); } catch { /* ignore */ }
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
        absorbedFiles.push(filePath);
    }
    if (absorbed.length > 0) {
        writeMailboxAt(canonicalPath, workerName, mailbox);
    }
    for (const filePath of absorbedFiles) {
        try { unlinkSync(filePath); } catch { /* ignore */ }
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

/**
 * Puts a refused trigger on the recipient team's timeline (T63e2): the recipient wakes only on a trigger, so
 * monitor and the user must see it was not woken. Callers write it after their own line about the same send
 * (the message, the board change), so the timeline reads in order (T65). Never throws: the message is
 * delivered either way, and the caller already warns about the trigger.
 */
export async function logRefusedTrigger(stateRoot, { team, from, to, pane, reason }) {
    try {
        return await appendEvent(stateRoot, { type: 'trigger-refused', team, worker: from, to, pane: pane ?? null, reason });
    } catch {
        return false;
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
 * message carries `trigger` ({sent, refused?}); a caller that logs the send logs
 * a refusal after it, with logRefusedTrigger.
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
        updateMailbox(teamName, fromWorker, cwd, (senderMailbox) => {
            senderMailbox.sent_pending[messageId] = {
                message_id: messageId,
                to_worker: toWorker,
                body,
                expects_reply: true,
                sent_at: createdAt,
            };
        });
    }

    // 2. Sender archive (direction=out) — durable record before delivery.
    appendArchive(teamName, fromWorker, cwd, { ...message, direction: 'out' });

    // 3. Drop into recipient's spool (commits delivery).
    dropSpoolMessage(teamName, toWorker, cwd, message, crossTeam?.toStateRoot);

    // 4. Notify the recipient via tmux (best-effort, and only into its own pane).
    const trigger = await sendTmuxTrigger(toPaneId, 'new-message', fromWorker, { session, worker: toWorker });

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
