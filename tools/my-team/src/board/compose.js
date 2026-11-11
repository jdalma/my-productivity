/**
 * The board's one assembly point (T63d, rfc/board-design.md §1): the only module that knows the adapters.
 * A team is a board team when its manifest carries the config's `board` item; its store is then
 * <state_root>/board.db (sqlite) or a memory store (tests). A team without the item gets board-unavailable
 * before any file is touched. The write service gets its ports here: the git checks (git.js), notices through
 * the mailbox (one line, no state: `[board] <ref> <action>`, §6.2) and a `board` line in events.jsonl.
 */

import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { loadManifest, manifestPathForTeam, rosterOf } from '../commands/_manifest.js';
import { appendEvent } from '../lib/events.js';
import { validateTeamName } from '../lib/team-name.js';
import { queueDirectMessage } from '../lib/tmux-comm.js';
import { BoardError } from './core/rules.js';
import { createBoard } from './core/service.js';
import { gitRange } from './git.js';
import { createMemoryStore } from './store/memory/index.js';
import { createSqliteStore } from './store/sqlite/index.js';

const fail = (code, message) => { throw new BoardError(code, message); };

export async function openBoard(teamName) {
    if (!teamName) fail('invalid', 'team_name is required');
    try { validateTeamName(teamName); } catch (err) { fail('invalid', err.message); }
    if (!existsSync(manifestPathForTeam(teamName))) fail('not-found', `no team '${teamName}' (no manifest at ${manifestPathForTeam(teamName)})`);
    const manifest = loadManifest(teamName);
    if (!manifest.board) fail('board-unavailable', `team '${teamName}' has no board in its config (add "board": {"store": "sqlite"})`);
    const store = manifest.board.store === 'memory' ? createMemoryStore() : createSqliteStore(join(manifest.state_root, 'board.db'));
    await store.open();
    return { store, roster: rosterOf(manifest), manifest, close: () => store.close() };
}

/** The write service for `actor`, with the team's notices, events and git checks wired in. */
export function boardFor({ store, roster, manifest, actor }) {
    const root = manifest.state_root;
    const notify = async (to, ref, action) => {
        // the mailbox paths follow MY_TEAM_STATE_ROOT; set it for these writes only (R70 L3)
        const saved = process.env.MY_TEAM_STATE_ROOT;
        process.env.MY_TEAM_STATE_ROOT = root;
        const warnings = [];
        try {
            for (const name of to) {
                const pane = manifest.workers.find((w) => w.name === name)?.pane_id;
                try {
                    const sent = await queueDirectMessage(manifest.team_name, actor, name, `[board] ${ref} ${action}`, pane, dirname(root),
                        null, false, null, manifest.session_name);
                    if (sent.trigger?.refused) warnings.push(`notice to ${name} not typed into its pane (${sent.trigger.refused}); it waits in the mailbox`);
                } catch (err) {
                    warnings.push(`notice to ${name}: ${err.message}`);
                }
            }
        } finally {
            if (saved === undefined) delete process.env.MY_TEAM_STATE_ROOT; else process.env.MY_TEAM_STATE_ROOT = saved;
        }
        return warnings;
    };
    const event = ({ worker, action, kind, ref, log_seq, state_from, state_to }) => appendEvent(root, {
        type: 'board', team: manifest.team_name, worker, action, kind, ref, log_seq,
        ...(state_from ? { state_from } : {}), ...(state_to ? { state_to } : {}),
    });
    return createBoard({ store, roster: () => roster, actor, now: () => new Date().toISOString(), git: gitRange, notify, event });
}

/**
 * The worker asking (T58's rule): the one MY_TEAM_WORKER names, in its own team only; without the variable
 * (the user's shell) the worker the input names. Catches mistakes, not intent.
 */
export function actorOf(env, teamName, roster, named) {
    const pinned = env.MY_TEAM_WORKER;
    let worker = named;
    if (pinned) {
        const slash = pinned.indexOf('/');
        const team = pinned.slice(0, slash);
        worker = pinned.slice(slash + 1);
        if (team !== teamName) fail('forbidden', `this process is worker '${worker}' of team '${team}' (MY_TEAM_WORKER=${pinned}), not of '${teamName}'`);
        if (named && named !== worker) fail('forbidden', `this process is '${worker}' (MY_TEAM_WORKER=${pinned}); it cannot ask as '${named}'`);
    }
    if (!worker) fail('invalid', 'name the worker: "worker" in the input (no MY_TEAM_WORKER here)');
    if (!roster.some((w) => w.name === worker)) fail('invalid', `'${worker}' is not in team '${teamName}'`);
    return worker;
}

/** A worker of another team (MY_TEAM_WORKER names one) does not read this board; the user's shell may (R69 L1). */
export function refuseOutsider(env, teamName) {
    const pinned = env.MY_TEAM_WORKER;
    if (pinned && pinned.slice(0, pinned.indexOf('/')) !== teamName) {
        fail('forbidden', `this process is a worker of another team (MY_TEAM_WORKER=${pinned}), not of '${teamName}'`);
    }
}

/** Opens the board, runs fn, closes it. */
export async function withBoard(teamName, fn) {
    const board = await openBoard(teamName);
    try { return await fn(board); } finally { await board.close(); }
}
