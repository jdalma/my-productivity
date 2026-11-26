/**
 * The board's one assembly point (T63d): the only module that knows the adapters.
 * A team is a board team when its manifest carries the config's `board` item; its store is then
 * <state_root>/board.db (sqlite) or a memory store (tests). A team without the item gets board-unavailable
 * before any file is touched. The write service gets its ports here: the git checks (git.js), notices through
 * the mailbox (one line, no state: `[board] <ref> <action>`; docs/board.md, Commands), a `board` line in events.jsonl,
 * and the file check behind the ticket and report path warnings.
 */

import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

import { loadManifest, manifestPathForTeam, rosterOf } from '../commands/_manifest.js';
import { appendEvent } from '../lib/events.js';
import { listPanes, liveness } from '../lib/team-liveness.js';
import { validateTeamName } from '../lib/team-name.js';
import { logRefusedTrigger, queueDirectMessage } from '../lib/tmux-comm.js';
import { MigrationRefused, SCHEMA_VERSION } from './core/contract.js';
import { BoardError } from './core/rules.js';
import { createBoard } from './core/service.js';
import { gitRange } from './git.js';
import { createMemoryStore } from './store/memory/index.js';
import { createSqliteStore } from './store/sqlite/index.js';

const fail = (code, message) => { throw new BoardError(code, message); };

/**
 * The team's board, for reading unless `write`: only a write may migrate the board file (T159), and not while the
 * team runs (T50): the my-team its workers run would then refuse the file. `panes` is tmux's pane list (tests pass one).
 */
export async function openBoard(teamName, { write = false, panes = listPanes } = {}) {
    if (!teamName) fail('invalid', 'team_name is required');
    try { validateTeamName(teamName); } catch (err) { fail('invalid', err.message); }
    if (!existsSync(manifestPathForTeam(teamName))) fail('not-found', `no team '${teamName}' (no manifest at ${manifestPathForTeam(teamName)})`);
    const manifest = loadManifest(teamName);
    if (!manifest.board) fail('board-unavailable', `team '${teamName}' has no board in its config (add "board": {"store": "sqlite"})`);
    const store = manifest.board.store === 'memory' ? createMemoryStore() : createSqliteStore(join(manifest.state_root, 'board.db'));
    const beforeMigrate = async (version) => {
        if (!liveness(manifest, await panes()).team_alive) return;
        throw new MigrationRefused(
            `team '${teamName}' is running and its board file has schema ${version}, older than this my-team's ${SCHEMA_VERSION}: `
            + 'a write would migrate it, and the my-team the team runs would then refuse it. Run this my-team on a copy: copy '
            + `${manifest.state_root} into a temporary folder, set MY_TEAM_STATE_ROOT_BASE to that folder, and in the copied manifest.json `
            + "change state_root to the copy's own folder (it is an absolute path) and session_name to one no tmux session has (the copy "
            + "is running too while it names this one). Or shut the team down and start it again with --continue: start migrates its "
            + 'board. Reads work as they are.',
        );
    };
    await store.open({ readonly: !write, beforeMigrate });
    return { store, roster: rosterOf(manifest), manifest, close: () => store.close() };
}

/** A board.db file opened for reading only, outside any team's manifest (start looks at the one it moves aside). */
export async function openBoardFileReadonly(file) {
    const store = createSqliteStore(file);
    await store.open({ readonly: true });
    return store;
}

/**
 * A board.db opened for writing once, outside any team's manifest, so it is migrated to this my-team's schema:
 * start --continue does it while the team is down (T50 R51 M1), since a write of the running team is refused.
 */
export async function migrateBoardFile(file) {
    const store = createSqliteStore(file);
    await store.open();
    await store.close();
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
                    if (sent.trigger?.refused) {
                        warnings.push(`notice to ${name} not typed into its pane (${sent.trigger.refused}); it waits in the mailbox`);
                        await logRefusedTrigger(root, { team: manifest.team_name, from: actor, to: name, pane, reason: sent.trigger.refused });
                    }
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
    return createBoard({ store, roster: () => roster, actor, now: () => new Date().toISOString(), git: gitRange, notify, event, fileExists: existsSync });
}

/**
 * The worker asking (T58's rule): the one MY_TEAM_WORKER names, in its own team only; without the variable
 * (the user's shell) the worker the input names, in `field` (board writes read `by`). Catches mistakes, not intent.
 */
export function actorOf(env, teamName, roster, named, field = 'worker') {
    const pinned = env.MY_TEAM_WORKER;
    let worker = named;
    if (pinned) {
        const slash = pinned.indexOf('/');
        const team = pinned.slice(0, slash);
        worker = pinned.slice(slash + 1);
        if (team !== teamName) fail('forbidden', `this process is worker '${worker}' of team '${team}' (MY_TEAM_WORKER=${pinned}), not of '${teamName}'`);
        if (named && named !== worker) fail('forbidden', `this process is '${worker}' (MY_TEAM_WORKER=${pinned}); it cannot ask as '${named}'`);
    }
    if (!worker) fail('invalid', `name the worker: "${field}" in the input (no MY_TEAM_WORKER here)`);
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

/** Opens the board (for reading, unless `write`), runs fn, closes it. */
export async function withBoard(teamName, fn, options) {
    const board = await openBoard(teamName, options);
    try { return await fn(board); } finally { await board.close(); }
}
