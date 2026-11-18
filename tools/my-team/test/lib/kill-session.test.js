/**
 * The real kill functions shutdown calls end the team's tmux side right away (T62a, R63 R1): the grace wait
 * removed in 56da3ce sat both in shutdown.js and in these functions, and runShutdown's own test stubs them.
 * On the test run's tmux server (run-isolated.sh names it; tmux-utils adds -L).
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { killTeamSession, killWorkerPanes } from '../../src/lib/tmux-session.js';
import { tmuxExec } from '../../src/lib/tmux-utils.js';

/**
 * The old wait was 10 s by default (MY_TEAM_GRACE_MS). 9 s still catches it, a wait plus any tmux call
 * passing 10 s, and leaves a single tmux call room for the seconds a loaded full suite can make it take.
 */
const LIMIT_MS = 9000;

const alive = (target) => {
    try { tmuxExec(['has-session', '-t', target], { stdio: 'pipe' }); return true; } catch { return false; }
};

test('killTeamSession ends a detached team session at once', async () => {
    const name = `my-team-kill-test-${process.pid}`;
    tmuxExec(['new-session', '-d', '-s', name, 'sleep 60'], { stdio: 'pipe' });
    assert.equal(alive(name), true);
    const t0 = Date.now();
    await killTeamSession(`${name}:0`, ['%999'], '%998', { sessionMode: 'detached-session' });
    const took = Date.now() - t0;
    assert.equal(alive(name), false, 'the session is gone');
    assert.ok(took < LIMIT_MS, `killTeamSession took ${took}ms: a wait is back`);
});

test('killWorkerPanes ends the worker panes at once and leaves the leader pane', async () => {
    const name = `my-team-kill-panes-${process.pid}`;
    tmuxExec(['new-session', '-d', '-s', name, 'sleep 60'], { stdio: 'pipe' });
    const leader = tmuxExec(['display-message', '-p', '-t', name, '#{pane_id}'], { stdio: 'pipe' }).trim();
    const worker = tmuxExec(['split-window', '-d', '-P', '-F', '#{pane_id}', '-t', name, 'sleep 60'], { stdio: 'pipe' }).trim();
    try {
        const t0 = Date.now();
        await killWorkerPanes({ paneIds: [leader, worker], leaderPaneId: leader });
        const took = Date.now() - t0;
        const panes = tmuxExec(['list-panes', '-t', name, '-F', '#{pane_id}'], { stdio: 'pipe' }).trim().split('\n');
        assert.deepEqual(panes, [leader]);
        assert.ok(took < LIMIT_MS, `killWorkerPanes took ${took}ms: a wait is back`);
    } finally {
        try { tmuxExec(['kill-session', '-t', name], { stdio: 'pipe' }); } catch { /* gone */ }
    }
});
