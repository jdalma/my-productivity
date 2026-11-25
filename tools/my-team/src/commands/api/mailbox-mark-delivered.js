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
 * The read-modify-write runs under the mailbox lock (updateMailbox), so a
 * concurrent mailbox-list or send cannot lose this removal or be lost by it.
 */

import { readFileSync, existsSync } from 'fs';
import { dirname } from 'path';
import { loadManifest } from '../_manifest.js';
import { setStateRoot } from '../../lib/state-root.js';
import { TeamPaths } from '../../lib/state-paths.js';
import { appendFileWithMode, ensureDirWithMode } from '../../lib/fs-utils.js';
import { updateMailbox } from '../../lib/tmux-comm.js';
import { requireTeamAndWorker, resolveTeamPath } from '../../lib/handler-guards.js';

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

export function runApiMailboxMarkDelivered(input, deps = {}) {
    const { teamName, worker } = requireTeamAndWorker(input, { env: deps.env ?? process.env });
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

    return updateMailbox(teamName, worker, parentDir, (mailbox) => {
        const target = mailbox.inbox[messageId];

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

        delete mailbox.inbox[messageId];
        return { ok: true, message_id: messageId };
    });
}
