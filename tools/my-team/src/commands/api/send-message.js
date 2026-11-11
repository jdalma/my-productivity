/**
 * `my-team api send-message` — worker → worker mailbox.
 *
 * Input JSON:
 *   { team_name, from_worker, to_worker, body, reply_to?, expects_reply?, to_team? }
 *
 * `to_worker` must be a worker name in the team. The legacy
 * `leader-fixed` recipient is no longer supported: peer-to-peer model
 * (user observes each pane directly) means workers report to the user
 * via their pane stdout, not via a leader channel.
 *
 * ## Cross-team delivery (`to_team`)
 *
 * With `to_team` set, the recipient is looked up in ANOTHER running team,
 * addressed by its stable TEAM NAME (the manifest at
 * ~/.my-team/sessions/<team>/manifest.json is keyed by it). Omit it and the
 * recipient is resolved inside the sender's own team. The older `to_session`
 * (tmux session name) form is gone — never used in practice — and is rejected
 * so a stale prompt cannot fall through to a same-team send.
 *
 * Either way, tmux stays authoritative for LIVENESS: the recipient's pane is
 * resolved from tmux (via each pane's `@worker_name` option) against the
 * session recorded in the target manifest, so a dead team fails loudly
 * instead of spooling a message nobody will read. A manifest always points at
 * the NEWEST run of its team, which is exactly the run `to_team` should reach.
 *
 * ## Role guard (teams with orchestrator/worker roles)
 *
 * When manifests carry worker roles, this command enforces the routing rules
 * the AGENTS.md overlay describes — cross-team only; inside a team every
 * worker may message every other:
 *   - role 'worker' senders cannot send cross-team.
 *   - cross-team messages into a role-declaring team must address one of its
 *     orchestrators (the team's gateway).
 * Legacy manifests without roles are untouched — fully peer-symmetric.
 */

import { loadManifest } from '../_manifest.js';
import { setStateRoot } from '../../lib/state-root.js';
import { queueDirectMessage } from '../../lib/tmux-comm.js';
import { appendMessageEvent } from '../../lib/events.js';
import { sanitizeName, validateTeamName } from '../../lib/team-name.js';
import { resolvePaneBySessionWorker } from '../../lib/tmux-utils.js';

/** Session names may carry a ":<window>" suffix in manifests but not in `tmux ls`. */
function stripWindowSuffix(name) {
    return typeof name === 'string' ? name.split(':')[0] : name;
}

/**
 * `deps` follows the same injection seam as runAddWorker: tests have no live
 * tmux server, so the one tmux-touching call is swappable while the disk side
 * (spool / archive / events) runs for real.
 */
function rolesOf(manifest) {
    const roles = new Map();
    for (const w of manifest.workers ?? []) roles.set(sanitizeName(w.name), w.role ?? null);
    return roles;
}

function orchestratorsOf(manifest) {
    return (manifest.workers ?? []).filter((w) => w.role === 'orchestrator').map((w) => w.name);
}

function teamUsesRoles(manifest) {
    return (manifest.workers ?? []).some((w) => w.role === 'orchestrator' || w.role === 'worker');
}

/**
 * The sender a worker process may claim (T58): the worker MY_TEAM_WORKER names (`<team>/<worker>`, set by
 * start and add-worker), in its own team only. A cross-team send still names the sender's own team as
 * team_name (to_team is the recipient's), so a worker naming another team as team_name is posing as that
 * team's member. Without the variable (the user's shell) the input stands. Catches mistakes, not intent:
 * a process can run with the variable changed.
 */
function senderFrom(env, teamName, fromWorker) {
    const pinned = env.MY_TEAM_WORKER;
    if (!pinned) {
        if (!fromWorker) throw new Error('from_worker is required');
        return fromWorker;
    }
    const slash = pinned.indexOf('/');
    const team = pinned.slice(0, slash), worker = pinned.slice(slash + 1);
    if (team !== teamName) {
        throw new Error(`This process is worker '${worker}' of team '${team}' (MY_TEAM_WORKER=${pinned}); send with team_name "${team}"`
            + ' and, for another team, to_team.');
    }
    if (fromWorker && sanitizeName(fromWorker) !== sanitizeName(worker)) {
        throw new Error(`This process was started as '${worker}' (MY_TEAM_WORKER=${pinned}); send with from_worker "${worker}"`
            + ' or leave it out.');
    }
    return worker;
}

export async function runApiSendMessage(input, deps = {}) {
    const resolvePane = deps.resolvePaneBySessionWorker ?? resolvePaneBySessionWorker;
    const writeEvent = deps.appendMessageEvent ?? appendMessageEvent;
    const { team_name, to_worker, body, reply_to, expects_reply, to_team, to_session } = input ?? {};
    if (!team_name) throw new Error('team_name is required');
    const from_worker = senderFrom(deps.env ?? process.env, team_name, input?.from_worker);
    if (!to_worker) throw new Error('to_worker is required');
    if (typeof body !== 'string' || !body) throw new Error('body is required');
    if (expects_reply !== undefined && typeof expects_reply !== 'boolean') {
        throw new Error('expects_reply must be a boolean when provided');
    }
    if (to_session !== undefined) {
        throw new Error('to_session was removed; address other teams by name with to_team.');
    }
    if (to_worker === 'leader-fixed') {
        throw new Error(
            "'leader-fixed' recipient is no longer supported. my-team uses a peer-to-peer model — surface user-facing messages via this pane's stdout (normal CLI prompt). For worker-to-worker, use a peer worker name."
        );
    }

    validateTeamName(team_name);
    const safeFrom = sanitizeName(from_worker);
    const safeTo = sanitizeName(to_worker);
    const expectsReply = Boolean(expects_reply);

    const isCrossTeam = Boolean(to_team);

    // Same-team only: with to_team set, an identically-named worker
    // in another team is a different worker entirely, so a reply can resolve.
    if (!isCrossTeam && safeFrom === safeTo && expectsReply) {
        throw new Error(
            `Self-message with expects_reply=true is not supported (from_worker === to_worker === "${safeFrom}"). ` +
            `Self-replies cannot resolve sent_pending because the same worker owns both sides; ` +
            `use expects_reply=false for self-notifications or send to a peer.`
        );
    }

    const manifest = loadManifest(team_name);
    process.env.MY_TEAM_STATE_ROOT = manifest.state_root;
    setStateRoot(manifest.state_root);

    // Both sender and recipient must be known team members. Sanitizer already
    // removed traversal characters; these checks enforce roster membership so
    // a hallucinated `from_worker` (e.g. typed into a pane by an external
    // text expander) cannot inject a peer message that has no origin in the
    // team. Without this guard, a forged `new-message:<from>` trigger could
    // arrive in a recipient pane with no trace in events.jsonl/archive,
    // because the spool write would silently succeed.
    const sender = manifest.workers.find((w) => sanitizeName(w.name) === safeFrom);
    if (!sender) {
        throw new Error(
            `Sender '${from_worker}' not in team '${team_name}'. ` +
            `Known workers: ${manifest.workers.map((w) => w.name).join(', ')}.`
        );
    }

    // Role guard, sender side: a role-'worker' sender never crosses team
    // boundaries — its orchestrator is the team's gateway.
    const senderRole = sender.role ?? null;
    if (isCrossTeam && senderRole === 'worker') {
        const orchs = orchestratorsOf(manifest);
        throw new Error(
            `Worker '${from_worker}' has role 'worker' and cannot send cross-team messages. ` +
            `Report to your orchestrator (${orchs.join(', ') || 'none configured'}) and let it relay.`
        );
    }

    // Recipient resolution. Same-team (no to_team) keeps the
    // original path untouched: roster lookup + the pane id recorded in our own
    // manifest. Cross-team resolves the recipient's state_root from ITS
    // manifest and its pane from tmux — see the module header for why those
    // come from different sources.
    let recipientPaneId;
    let crossTeam = null;
    if (isCrossTeam) {
        const targetManifest = loadManifest(to_team);
        const targetWorker = targetManifest.workers?.find((w) => sanitizeName(w.name) === safeTo);
        if (!targetWorker) {
            const names = (targetManifest.workers ?? []).map((w) => w.name).join(', ');
            throw new Error(
                `Recipient '${to_worker}' not in team '${targetManifest.team_name}'. ` +
                `Known workers: ${names || '(none)'}.`
            );
        }
        // Role guard, recipient side: a role-declaring team accepts inbound
        // cross-team messages only through its orchestrators (gateway).
        if (teamUsesRoles(targetManifest) && targetWorker.role !== 'orchestrator') {
            const orchs = orchestratorsOf(targetManifest);
            throw new Error(
                `Cross-team messages into team '${targetManifest.team_name}' must address one of its ` +
                `orchestrators (${orchs.join(', ') || 'none configured'}), not '${to_worker}'.`
            );
        }
        // tmux is authoritative for liveness: this throws if the session is
        // gone, which is exactly what we want — a spool file written for a dead
        // session would sit unread forever with the send reporting success.
        recipientPaneId = await resolvePane(stripWindowSuffix(targetManifest.session_name), targetWorker.name);
        crossTeam = { toTeam: targetManifest.team_name, toStateRoot: targetManifest.state_root };
    } else {
        const recipient = manifest.workers.find((w) => sanitizeName(w.name) === safeTo);
        if (!recipient) {
            throw new Error(`Recipient '${to_worker}' not in team '${team_name}'`);
        }
        // No same-team role guard: peers in one team may talk freely (workers
        // sharing a repo must be able to check whether their changes collide).
        // Roles gate only the cross-team paths above.
        recipientPaneId = recipient.pane_id;
    }

    // Soft guard: a body containing '?' usually implies a question. Warn (not
    // throw) when expects_reply was not explicitly set. The sender remains in
    // charge — the warning surfaces only on stderr.
    let expectsReplyHint = null;
    if (expects_reply === undefined && /[?？]/.test(body)) {
        expectsReplyHint = 'body contains "?" but expects_reply was not provided — pass expects_reply:true if you need an answer';
        process.stderr.write(`[my-team] ${expectsReplyHint}\n`);
    }

    const parentDir = manifest.state_root.replace(/\/[^/]+$/, '');
    const message = await queueDirectMessage(
        team_name, safeFrom, safeTo, body, recipientPaneId, parentDir,
        reply_to ?? null,
        expectsReply,
        crossTeam
    );

    // The message is delivered by now: a log line that cannot be made or written is a warning, never an
    // error, or the sender would send again and the recipient get it twice (R61 L1).
    const logWarnings = [];
    const logEvent = async (stateRoot, fields) => {
        let written = false;
        try { written = await writeEvent(stateRoot, fields); } catch (err) { process.stderr.write(`[my-team] events.jsonl: ${err.message}\n`); }
        if (!written) logWarnings.push(`not logged in ${stateRoot}/events.jsonl`);
    };
    const eventExtra = crossTeam ? { to_team: crossTeam.toTeam } : {};
    await logEvent(manifest.state_root, {
        team: team_name,
        from: safeFrom,
        to: safeTo,
        body,
        message_id: message.message_id,
        reply_to: message.reply_to,
        expects_reply: message.expects_reply,
        ...eventExtra,
    });
    // Mirror the event into the recipient team's log too. Without this the
    // message is invisible to `my-team monitor` on the receiving side — the
    // recipient would answer a message its own timeline never recorded.
    if (crossTeam) {
        await logEvent(crossTeam.toStateRoot, {
            team: team_name,
            from: safeFrom,
            to: safeTo,
            body,
            message_id: message.message_id,
            reply_to: message.reply_to,
            expects_reply: message.expects_reply,
            from_team: team_name,
            ...eventExtra,
        });
    }

    return {
        ok: true,
        delivered_to: safeTo,
        message_id: message.message_id,
        reply_to: message.reply_to,
        expects_reply: message.expects_reply,
        ...(crossTeam ? { delivered_to_team: crossTeam.toTeam } : {}),
        ...(expectsReplyHint ? { hint: expectsReplyHint } : {}),
        ...(logWarnings.length ? { warning: `delivered, but ${logWarnings.join('; ')}` } : {}),
    };
}
