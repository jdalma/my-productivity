/**
 * createTeamSession's topology (T5): called from inside tmux it splits the caller's window, unless the
 * team asks for a detached session. Detached wins over new_window: the team then has a session of its own
 * and no window in the caller's. On the test run's tmux server (run-isolated.sh names it; tmux-utils adds -L).
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { createTeamSession } from '../../src/lib/tmux-session.js';
import { tmuxExec } from '../../src/lib/tmux-utils.js';

const sessions = () => tmuxExec(['list-sessions', '-F', '#{session_name}'], { stdio: 'pipe' }).trim().split('\n');
const windows = (s) => tmuxExec(['list-windows', '-t', s, '-F', '#{window_index}'], { stdio: 'pipe' }).trim().split('\n');

/** Run fn as if called from a pane of a caller session on the test server: TMUX and TMUX_PANE point at it. */
async function fromCallerPane(fn) {
    const caller = `my-team-mode-caller-${process.pid}-${Date.now().toString(36)}`;
    const cwd = realpathSync(mkdtempSync(join(tmpdir(), 'my-team-mode-')));
    tmuxExec(['new-session', '-d', '-s', caller, 'sleep 60'], { stdio: 'pipe' });
    const pane = tmuxExec(['display-message', '-p', '-t', caller, '#{pane_id}'], { stdio: 'pipe' }).trim();
    const socket = tmuxExec(['display-message', '-p', '-t', caller, '#{socket_path},#{pid},0'], { stdio: 'pipe' }).trim();
    const saved = { TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE };
    const before = new Set(sessions());
    process.env.TMUX = socket;
    process.env.TMUX_PANE = pane;
    try {
        return await fn({ caller, cwd });
    } finally {
        for (const [k, v] of Object.entries(saved)) if (v === undefined) delete process.env[k]; else process.env[k] = v;
        for (const s of sessions()) {
            if (!before.has(s) || s === caller) try { tmuxExec(['kill-session', '-t', s], { stdio: 'pipe' }); } catch { /* gone */ }
        }
        rmSync(cwd, { recursive: true, force: true });
    }
}

test('inside tmux without detached, the team splits the caller window', async () => {
    await fromCallerPane(async ({ caller, cwd }) => {
        const s = await createTeamSession('mode-split', [{ name: 'a', cwd }], {});
        assert.equal(s.sessionMode, 'split-pane');
        assert.equal(s.sessionName.split(':')[0], caller);
    });
});

test('inside tmux with detached, the team gets a session of its own and the caller window is left alone', async () => {
    await fromCallerPane(async ({ caller, cwd }) => {
        const s = await createTeamSession('mode-detached', [{ name: 'a', cwd }], { detached: true });
        assert.equal(s.sessionMode, 'detached-session');
        assert.match(s.sessionName, /^my-team-mode-detached-/);
        assert.deepEqual(windows(caller), ['0']);
        assert.equal(tmuxExec(['list-panes', '-t', caller, '-F', '#{pane_id}'], { stdio: 'pipe' }).trim().split('\n').length, 1);
    });
});

test('detached together with new_window: detached wins, no window is added to the caller session', async () => {
    await fromCallerPane(async ({ caller, cwd }) => {
        const s = await createTeamSession('mode-both', [{ name: 'a', cwd }], { detached: true, newWindow: true });
        assert.equal(s.sessionMode, 'detached-session');
        assert.match(s.sessionName, /^my-team-mode-both-/);
        assert.deepEqual(windows(caller), ['0']);
    });
});
