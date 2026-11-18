/**
 * `my-team api archive-lookup` — find an archived message by message_id.
 *
 * Purpose: workers use this to resolve `reply_to` references when the
 * pointed-to message is no longer in mailbox.sent_pending (it was sent
 * without expects_reply, or it has already been answered and the
 * sent_pending entry was cleared). The worker's archive jsonl is the
 * durable record for those cases.
 *
 * Reply-correlation discipline (Phase C, CRITICAL #1 fix):
 *   1. mailbox-list returns sent_pending. If `reply_to` is in there, the
 *      message answers a question I'm still waiting on.
 *   2. Otherwise, call archive-lookup. A "direction: out" hit means I sent
 *      that message earlier (e.g., this is a follow-up to my prior reply).
 *      A "direction: in" hit means I received that message earlier (e.g.,
 *      this is a follow-up to a question I previously answered).
 *   3. If neither finds a hit, treat as a fresh message with a dangling
 *      reply_to and log it — likely a peer's bug, not a protocol error.
 *
 * Input JSON:
 *   { team_name, worker, message_id }
 *
 * Returns: { ok: true, worker, found: true, entry } where entry is the full
 * archive line including `direction` ("in" | "out"). When not found:
 * { ok: true, worker, found: false }.
 */

import { readFileSync, existsSync } from 'fs';
import { loadManifest } from '../_manifest.js';
import { setStateRoot } from '../../lib/state-root.js';
import { TeamPaths } from '../../lib/state-paths.js';
import { requireTeamAndWorker, resolveTeamPath } from '../../lib/handler-guards.js';

export function runApiArchiveLookup(input) {
    const { teamName, worker } = requireTeamAndWorker(input);
    const messageId = input?.message_id;
    if (!messageId) throw new Error('message_id is required');

    const manifest = loadManifest(teamName);
    process.env.MY_TEAM_STATE_ROOT = manifest.state_root;
    setStateRoot(manifest.state_root);

    const parentDir = manifest.state_root.replace(/\/[^/]+$/, '');
    const archiveFile = resolveTeamPath(teamName, worker, parentDir, TeamPaths.archive);

    if (!existsSync(archiveFile)) {
        return { ok: true, worker, found: false };
    }

    let raw;
    try {
        raw = readFileSync(archiveFile, 'utf-8');
    } catch (err) {
        throw new Error(`Cannot read archive at ${archiveFile}: ${err.message}`);
    }

    // Scan from the end — most reply targets are recent.
    const lines = raw.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i];
        if (!line.trim()) continue;
        let entry;
        try {
            entry = JSON.parse(line);
        } catch {
            continue;
        }
        if (entry && entry.message_id === messageId) {
            return { ok: true, worker, found: true, entry };
        }
    }
    return { ok: true, worker, found: false };
}
