/**
 * The pane listings read the same without a UTF-8 locale (T63e2, R70a R2). With LC_ALL=C, tmux prints a tab in
 * a format as '_'; listPanes and resolvePaneBySessionWorker must not depend on it, or liveness reads every
 * worker as dead and a cross-team send cannot find its recipient. On a tmux server of this file's own.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'fs';

import { listPanes } from '../../src/lib/team-liveness.js';
import { resolvePaneBySessionWorker, tmuxExec } from '../../src/lib/tmux-utils.js';

if (process.env.MY_TEAM_TEST_TMUX) {
    const own = `${process.env.MY_TEAM_TEST_TMUX}-locale`;
    process.env.MY_TEAM_TEST_TMUX = own;
    test.after(() => {
        try { tmuxExec(['kill-server'], { stdio: 'pipe' }); } catch { /* none */ }
        rmSync(`/tmp/tmux-${process.getuid()}/${own}`, { force: true });
    });
}

test('with LC_ALL=C, listPanes and resolvePaneBySessionWorker still read session, pane and worker', async (t) => {
    const saved = { LC_ALL: process.env.LC_ALL, LANG: process.env.LANG, LC_CTYPE: process.env.LC_CTYPE };
    t.after(() => { for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; } });
    tmuxExec(['new-session', '-d', '-s', 'loc-team', 'sleep 600'], { stdio: 'pipe' });
    t.after(() => { try { tmuxExec(['kill-session', '-t', 'loc-team'], { stdio: 'pipe' }); } catch { /* gone */ } });
    const pane = tmuxExec(['display-message', '-p', '-t', 'loc-team', '#{pane_id}'], { stdio: 'pipe' }).trim();
    tmuxExec(['set-option', '-p', '-t', pane, '@worker_name', 'core'], { stdio: 'pipe' });

    process.env.LC_ALL = 'C';
    delete process.env.LANG;
    delete process.env.LC_CTYPE;
    assert.deepEqual((await listPanes()).filter((p) => p.session === 'loc-team'), [{ session: 'loc-team', paneId: pane, worker: 'core' }]);
    assert.equal(await resolvePaneBySessionWorker('loc-team:0', 'core'), pane);
});
