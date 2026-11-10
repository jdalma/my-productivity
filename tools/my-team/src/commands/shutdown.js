/**
 * `my-team shutdown` — end a running team's tmux side. Its state_root is left as it is.
 * Implements AC-17, AC-18.
 */

import { resolveTeamManifest } from './_manifest.js';
import { setStateRoot } from '../lib/state-root.js';
import { killTeamSession, killWorkerPanes } from '../lib/tmux-session.js';

export async function runShutdown(opts) {
    if (!opts.team) throw new Error('--team is required');
    // Resolve --team as EITHER a team name OR a tmux session name (what
    // `tmux ls` shows), and report under the canonical team_name.
    const { manifest, teamName } = resolveTeamManifest(opts.team, opts.stateRoot);
    opts.team = teamName;
    process.env.MY_TEAM_STATE_ROOT = manifest.state_root;
    setStateRoot(manifest.state_root);

    const workerPaneIds = manifest.workers.map((w) => w.pane_id);
    const leaderPaneId = manifest.leader_pane;

    console.log(`[my-team] Shutting down team '${opts.team}' (mode: ${manifest.session_mode})...`);

    if (manifest.session_mode === 'split-pane') {
        // Kill worker panes only (preserve user's host pane)
        await killWorkerPanes({ paneIds: workerPaneIds, leaderPaneId });
    } else {
        // detached-session or dedicated-window: kill whole session/window
        await killTeamSession(
            manifest.session_name,
            workerPaneIds,
            leaderPaneId,
            { sessionMode: manifest.session_mode }
        );
    }

    // state_root stays: `start --continue` picks up its mail, work files and events.
    // The manifest stays too; with the session gone, status reads the team as stopped.
    console.log(`[my-team] Team '${opts.team}' shut down.`);
}
