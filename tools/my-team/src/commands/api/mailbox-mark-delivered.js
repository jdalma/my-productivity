/**
 * `my-team api mailbox-mark-delivered` — mark a worker's inbox entry consumed.
 *
 * Schema v2 behavior:
 *   - Find `inbox[message_id]` in the worker's mailbox JSON.
 *   - Append a corresponding entry to `archive/<worker>.jsonl` with
 *     `direction: "in"` and a fresh `consumed_at` timestamp.
 *   - Remove the entry from `inbox` so subsequent mailbox-list calls do not
 *     return it. The archive is the durable record.
 *
 * Input JSON:
 *   { team_name, worker, message_id }
 *
 * Returns: { ok: true, message_id, already_consumed?: true }
 *
 * Idempotent: if the entry is absent from the inbox map but a prior consumed
 * line exists in the archive jsonl, returns `already_consumed: true` instead
 * of throwing — re-marking is a safe no-op.
 *
 * Writes use atomicWriteJson (write-temp + rename) so a torn write is
 * impossible.
 */

import { readFileSync, existsSync } from 'fs';
import { dirname } from 'path';
import { loadManifest } from '../_manifest.js';
import { setStateRoot } from '../../lib/state-root.js';
import { TeamPaths } from '../../lib/state-paths.js';
import { atomicWriteJson, appendFileWithMode, ensureDirWithMode } from '../../lib/fs-utils.js';
import { MAILBOX_SCHEMA_VERSION } from '../../lib/tmux-comm.js';
import { requireTeamAndWorker, resolveTeamPath, assertMailboxSchemaVersion } from '../../lib/handler-guards.js';

function archiveHasMessage(archiveFile, messageId) {
    if (!existsSync(archiveFile)) return null;
    let raw;
    try {
        raw = readFileSync(archiveFile, 'utf-8');
    } catch {
        return null;
    }
    for (const line of raw.split('\n')) {
        if (!line.trim()) continue;
        try {
            const entry = JSON.parse(line);
            if (entry && entry.message_id === messageId && entry.direction === 'in') {
                return entry;
            }
        } catch {
            /* skip malformed line */
        }
    }
    return null;
}

export function runApiMailboxMarkDelivered(input) {
    const { teamName, worker } = requireTeamAndWorker(input);
    const messageId = input?.message_id;
    if (!messageId) throw new Error('message_id is required');

    const manifest = loadManifest(teamName);
    process.env.MY_TEAM_STATE_ROOT = manifest.state_root;
    setStateRoot(manifest.state_root);

    const parentDir = manifest.state_root.replace(/\/[^/]+$/, '');
    const mailboxFile = resolveTeamPath(teamName, worker, parentDir, TeamPaths.mailbox);
    const archiveFile = resolveTeamPath(teamName, worker, parentDir, TeamPaths.archive);

    if (!existsSync(mailboxFile)) {
        throw new Error(`mailbox not found at ${mailboxFile}`);
    }

    let parsed;
    try {
        parsed = JSON.parse(readFileSync(mailboxFile, 'utf-8'));
    } catch (err) {
        throw new Error(`Mailbox at ${mailboxFile} is not valid JSON: ${err.message}`);
    }

    assertMailboxSchemaVersion(parsed, mailboxFile);

    const inbox = parsed?.inbox && typeof parsed.inbox === 'object' ? parsed.inbox : {};
    const target = inbox[messageId];

    if (!target) {
        // Already archived? Treat as idempotent re-mark.
        const archived = archiveHasMessage(archiveFile, messageId);
        if (archived) {
            return { ok: true, message_id: messageId, already_consumed: true };
        }
        throw new Error(`message_id '${messageId}' not found in mailbox for worker '${worker}'`);
    }

    const consumedAt = new Date().toISOString();
    const archiveEntry = { ...target, consumed_at: consumedAt, direction: 'in' };

    ensureDirWithMode(dirname(archiveFile));
    appendFileWithMode(archiveFile, JSON.stringify(archiveEntry) + '\n');

    delete inbox[messageId];
    atomicWriteJson(mailboxFile, {
        schema_version: MAILBOX_SCHEMA_VERSION,
        worker,
        inbox,
        sent_pending: parsed?.sent_pending && typeof parsed.sent_pending === 'object' ? parsed.sent_pending : {},
    });

    return { ok: true, message_id: messageId };
}
