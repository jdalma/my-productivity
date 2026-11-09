/**
 * `my-team status` — show team state and worker liveness.
 *
 * Besides tmux liveness, each worker line surfaces what only its own files
 * know: the self-reported state from status.json (blocked + reason is the
 * one that matters) and mail that is stuck — spool files never absorbed,
 * inbox entries never consumed, questions still waiting for an answer.
 * Those are the signals of a worker that stalled without saying so.
 */

import { readdir, readFile } from 'fs/promises';
import { join } from 'path';

import { loadManifest } from './_manifest.js';
import { getStateRootBase, setStateRoot } from '../lib/state-root.js';
import { tmuxCmdAsync } from '../lib/tmux-utils.js';
import { readMailboxFile } from '../lib/tmux-comm.js';
import { TeamPaths } from '../lib/state-paths.js';

async function mailAndState(teamName, workerName) {
    let state = null, reason = null;
    try {
        const s = JSON.parse(await readFile(TeamPaths.workerStatus(teamName, workerName), 'utf-8'));
        state = s.state ?? null;
        reason = s.reason ?? null;
    } catch { /* never written */ }

    let spool = 0;
    try {
        spool = (await readdir(TeamPaths.incomingSpoolDir(teamName, workerName))).filter((n) => n.endsWith('.json')).length;
    } catch { /* no spool dir */ }

    let unread = 0, sentPending = 0, oldestPendingAt = null;
    try {
        const mb = await readMailboxFile(teamName, workerName, process.cwd());
        unread = Object.keys(mb.inbox).length;
        const pending = Object.values(mb.sent_pending);
        sentPending = pending.length;
        oldestPendingAt = pending.map((p) => p.sent_at).filter(Boolean).sort()[0] ?? null;
    } catch (err) {
        reason = reason ?? `mailbox unreadable: ${err.message}`;
    }

    return { state, reason, spool, unread, sent_pending: sentPending, oldest_pending_at: oldestPendingAt };
}

function hoursSince(iso) {
    return Math.round((Date.now() - Date.parse(iso)) / 3_600_000);
}

/**
 * All panes on the tmux server as {session, paneId, worker}. Empty when no
 * tmux server is running (every team is then dead).
 */
async function listPanes() {
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
 * Liveness by (session, @worker_name), not by pane id alone: tmux pane ids are
 * server-global and get reused, so a dead team's manifest can point at another
 * team's live pane. A worker is alive only if its team session exists AND that
 * session holds a pane tagged with the worker's name AND it is the manifest's
 * pane (a re-spawned worker with a new pane id means the manifest is stale).
 */
export function liveness(manifest, panes) {
    const session = manifest.session_name.split(':')[0];
    const inSession = panes.filter((p) => p.session === session);
    return {
        team_alive: inSession.length > 0,
        alive: Object.fromEntries(manifest.workers.map((w) => [
            w.name,
            inSession.some((p) => p.worker === w.name && p.paneId === w.pane_id),
        ])),
    };
}

/** Team dirs to scan for `--all`: `.bak` copies and `.omc` are not teams. */
export function teamDirs(names) {
    return names.filter((n) => !n.endsWith('.bak') && n !== '.omc');
}

async function teamStatus(manifest, panes) {
    process.env.MY_TEAM_STATE_ROOT = manifest.state_root;
    setStateRoot(manifest.state_root);
    const { team_alive, alive } = liveness(manifest, panes);
    const workers = await Promise.all(manifest.workers.map(async (w) => ({
        ...w,
        alive: alive[w.name],
        ...(await mailAndState(manifest.team_name, w.name)),
    })));
    return {
        team_name: manifest.team_name,
        state_root: manifest.state_root,
        session: manifest.session_name,
        session_mode: manifest.session_mode,
        started_at: manifest.started_at,
        team_alive,
        workers,
    };
}

async function runStatusAll() {
    const base = getStateRootBase();
    const panes = await listPanes();
    const teams = [];
    let entries;
    try {
        entries = await readdir(base, { withFileTypes: true });
    } catch (err) {
        if (err.code !== 'ENOENT') throw err;
        entries = []; // no team ever started on this machine
    }
    for (const name of teamDirs(entries.filter((d) => d.isDirectory()).map((d) => d.name)).sort()) {
        let manifest;
        try {
            manifest = JSON.parse(await readFile(join(base, name, 'manifest.json'), 'utf-8'));
        } catch (err) {
            if (err.code !== 'ENOENT') console.error(`skip ${name}: ${err.message}`);
            continue;
        }
        teams.push(await teamStatus(manifest, panes));
    }
    console.log(JSON.stringify({ teams }, null, 2));
}

export async function runStatus(opts) {
    if (opts.all) {
        if (!opts.json) throw new Error('--all requires --json');
        if (opts.team) throw new Error('--all and --team are mutually exclusive');
        return runStatusAll();
    }
    if (!opts.team) throw new Error('--team is required');
    const manifest = loadManifest(opts.team, opts.stateRoot);
    const status = await teamStatus(manifest, await listPanes());
    const workerStatus = status.workers;

    if (opts.json) {
        console.log(JSON.stringify(status, null, 2));
        return;
    }

    console.log(`Team: ${manifest.team_name}`);
    console.log(`State root: ${manifest.state_root}`);
    console.log(`Tmux session: ${manifest.session_name} (${manifest.session_mode})`);
    console.log(`Started: ${manifest.started_at}`);
    console.log(`\nWorkers (${workerStatus.length}):`);
    const nameWidth = Math.max(...workerStatus.map((w) => w.name.length));
    for (const w of workerStatus) {
        const dot = w.alive ? '●' : '○';
        const pending = w.sent_pending
            ? `pending=${w.sent_pending} (oldest ${hoursSince(w.oldest_pending_at)}h)`
            : 'pending=0';
        console.log(
            `  ${dot} ${w.name.padEnd(nameWidth)} ${(w.alive ? 'alive' : 'dead').padEnd(5)}  ` +
            `state=${(w.state ?? '-').padEnd(8)} spool=${w.spool} unread=${w.unread} ${pending}  cwd=${w.cwd}`
        );
        if (w.state === 'blocked' && w.reason) console.log(`      reason: ${w.reason}`);
    }
}
