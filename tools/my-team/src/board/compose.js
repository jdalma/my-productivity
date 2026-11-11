/**
 * The board's one assembly point (T63d, rfc/board-design.md §1): the only module that knows the adapters.
 * A team is a board team when its manifest carries the config's `board` item; its store is then
 * <state_root>/board.db (sqlite) or a memory store (tests). A team without the item gets board-unavailable
 * before any file is touched.
 */

import { existsSync } from 'node:fs';
import { join } from 'node:path';

import { loadManifest, manifestPathForTeam, rosterOf } from '../commands/_manifest.js';
import { validateTeamName } from '../lib/team-name.js';
import { BoardError } from './core/rules.js';
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
    return { store, roster: rosterOf(manifest), close: () => store.close() };
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

/** Opens the board, runs fn, closes it. */
export async function withBoard(teamName, fn) {
    const board = await openBoard(teamName);
    try { return await fn(board); } finally { await board.close(); }
}
