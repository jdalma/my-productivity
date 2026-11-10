/**
 * Whether a team and its workers are live, from tmux alone. One rule for
 * status, start's running guard, remove-worker and shutdown.
 */

import { readFile } from 'fs/promises';
import { join } from 'path';

import { tmuxCmdAsync } from './tmux-utils.js';

/**
 * All panes on the tmux server as {session, paneId, worker}. Empty when no
 * tmux server is running (every team is then dead).
 */
export async function listPanes() {
    let stdout;
    try {
        ({ stdout } = await tmuxCmdAsync(['list-panes', '-a', '-F', '#{session_name}\t#{pane_id}\t#{@worker_name}']));
    } catch {
        return [];
    }
    return stdout.split('\n').filter(Boolean).map((line) => {
        const [session, paneId, worker] = line.split('\t');
        return { session, paneId, worker: (worker ?? '').trim() };
    });
}

/**
 * Liveness by (session, @worker_name, pane id), not by pane id alone: tmux pane
 * ids are server-global and get reused, so a stopped team's manifest can point
 * at another team's live pane. A worker is alive only if its team session holds
 * a pane tagged with the worker's name AND it is the manifest's pane (a
 * re-spawned worker with a new pane id means the manifest is stale). The team
 * is alive while one of its workers is: the session alone is not enough, since
 * a split-pane team's session is the user's and outlives the team.
 */
export function liveness(manifest, panes) {
    const session = manifest.session_name.split(':')[0];
    const inSession = panes.filter((p) => p.session === session);
    const alive = Object.fromEntries(manifest.workers.map((w) => [
        w.name,
        inSession.some((p) => p.worker === w.name && p.paneId === w.pane_id),
    ]));
    return { team_alive: Object.values(alive).some(Boolean), alive };
}

/** The team whose manifest is in `stateRoot` is live now; false with no manifest. */
export async function runningByManifest(stateRoot, panes = listPanes) {
    let manifest;
    try {
        manifest = JSON.parse(await readFile(join(stateRoot, 'manifest.json'), 'utf-8'));
    } catch {
        return false;
    }
    return liveness(manifest, await panes()).team_alive;
}
