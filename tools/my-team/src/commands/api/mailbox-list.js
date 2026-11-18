/**
 * `my-team api mailbox-list` — read a worker's mailbox (schema v2, Phase B).
 *
 * Before returning, absorbs any messages in the worker's incoming-spool into
 * its mailbox.inbox. This is the **only** place where spool→inbox transfer
 * happens, preserving the "worker owns its mailbox" invariant.
 *
 * Input JSON:
 *   { team_name, worker, unread_only? = true }
 *
 * Returns: { ok: true, worker, messages: [...], sent_pending: [...], roster: [...] }
 *
 *   - messages: inbox map projected to an array, sorted by created_at asc.
 *     Object key order is NOT a contract — use the array.
 *     With unread_only=true (default), entries with consumed_at set are
 *     filtered out.
 *   - sent_pending: the sender-side pending map projected to an array,
 *     sorted by sent_at asc.
 *   - roster: the team's CURRENT members from the manifest. A running worker
 *     only ever read its AGENTS.md roster at boot; add-worker changes the
 *     team after that, and this field is how the change reaches it — on the
 *     poll it already makes every cycle.
 */

import { readFileSync, existsSync } from 'fs';
import { loadManifest, rosterOf } from '../_manifest.js';
import { setStateRoot } from '../../lib/state-root.js';
import { TeamPaths } from '../../lib/state-paths.js';
import { absorbIncomingSpool } from '../../lib/tmux-comm.js';
import { requireTeamAndWorker, resolveTeamPath, assertMailboxSchemaVersion } from '../../lib/handler-guards.js';

function sortByCreatedAt(a, b) {
    return String(a.created_at ?? '').localeCompare(String(b.created_at ?? ''));
}

export async function runApiMailboxList(input) {
    const { teamName, worker } = requireTeamAndWorker(input);
    const onlyUnread = input?.unread_only === undefined ? true : Boolean(input.unread_only);

    const manifest = loadManifest(teamName);
    process.env.MY_TEAM_STATE_ROOT = manifest.state_root;
    setStateRoot(manifest.state_root);

    const parentDir = manifest.state_root.replace(/\/[^/]+$/, '');

    // Pull anything dropped into the spool into the worker's own mailbox.
    // This may write to mailbox.json; safe because the worker is the sole writer.
    await absorbIncomingSpool(teamName, worker, parentDir);

    const mailboxFile = resolveTeamPath(teamName, worker, parentDir, TeamPaths.mailbox);

    if (!existsSync(mailboxFile)) {
        return { ok: true, worker, messages: [], sent_pending: [], roster: rosterOf(manifest) };
    }

    let raw;
    try {
        raw = readFileSync(mailboxFile, 'utf-8');
    } catch (err) {
        throw new Error(`Cannot read mailbox at ${mailboxFile}: ${err.message}`);
    }

    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (err) {
        throw new Error(`Mailbox at ${mailboxFile} is not valid JSON: ${err.message}`);
    }

    assertMailboxSchemaVersion(parsed, mailboxFile);

    const inboxMap = parsed?.inbox && typeof parsed.inbox === 'object' ? parsed.inbox : {};
    const inboxEntries = Object.values(inboxMap);
    const filtered = onlyUnread ? inboxEntries.filter((m) => m && m.consumed_at == null) : inboxEntries;
    filtered.sort(sortByCreatedAt);

    const sentPendingMap = parsed?.sent_pending && typeof parsed.sent_pending === 'object' ? parsed.sent_pending : {};
    const sentPending = Object.values(sentPendingMap).slice();
    sentPending.sort((a, b) => String(a.sent_at ?? '').localeCompare(String(b.sent_at ?? '')));

    return { ok: true, worker, messages: filtered, sent_pending: sentPending, roster: rosterOf(manifest) };
}
