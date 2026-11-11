/**
 * Liveness must key on (session, @worker_name), not pane id alone: tmux pane
 * ids are server-global and reused, so a dead team's stale manifest can point
 * at another team's live pane and be reported alive.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { teamDirs } from '../../src/commands/status.js';
import { liveness, runningByManifest } from '../../src/lib/team-liveness.js';

const manifest = {
    session_name: 'my-team-dead-abc:0',
    workers: [
        { name: 'pm', pane_id: '%1' },
        { name: 'dev', pane_id: '%2' },
    ],
};

test('stale manifest whose pane ids were reused by another team → team and workers dead', () => {
    const panes = [
        { session: 'my-team-other-xyz', paneId: '%1', worker: 'pm' },
        { session: 'my-team-other-xyz', paneId: '%2', worker: 'dev' },
    ];
    assert.deepEqual(liveness(manifest, panes), { team_alive: false, alive: { pm: false, dev: false } });
});

test('live session: alive only when @worker_name and pane id both match', () => {
    const panes = [
        { session: 'my-team-dead-abc', paneId: '%0', worker: '' },
        { session: 'my-team-dead-abc', paneId: '%1', worker: 'pm' },
        { session: 'my-team-dead-abc', paneId: '%9', worker: 'dev' },
    ];
    assert.deepEqual(liveness(manifest, panes), { team_alive: true, alive: { pm: true, dev: false } });
});

test('a split-pane team after shutdown: the host session lives on, the team does not (M2)', () => {
    const split = { session_name: 'host:0', workers: manifest.workers };
    const panes = [{ session: 'host', paneId: '%0', worker: '' }];
    assert.deepEqual(liveness(split, panes), { team_alive: false, alive: { pm: false, dev: false } });
});

test('a session with only its host pane left is not a live team', () => {
    const panes = [{ session: 'my-team-dead-abc', paneId: '%0', worker: '' }];
    assert.equal(liveness(manifest, panes).team_alive, false);
});

test('a running split-pane team is found from its manifest, so a new start is refused (M3)', async () => {
    const { mkdtempSync, writeFileSync, rmSync } = await import('fs');
    const { tmpdir } = await import('os');
    const { join } = await import('path');
    const root = mkdtempSync(join(tmpdir(), 'my-team-running-'));
    try {
        assert.equal(await runningByManifest(root, async () => []), false, 'no manifest: nothing runs');
        writeFileSync(join(root, 'manifest.json'), JSON.stringify({ session_name: 'host:0', workers: manifest.workers }));
        const live = [{ session: 'host', paneId: '%0', worker: '' }, { session: 'host', paneId: '%1', worker: 'pm' }];
        assert.equal(await runningByManifest(root, async () => live), true);
        assert.equal(await runningByManifest(root, async () => [live[0]]), false, 'stopped: host pane only');
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});

test('no tmux server → everything dead', () => {
    assert.deepEqual(liveness(manifest, []), { team_alive: false, alive: { pm: false, dev: false } });
});

test('--all skips .bak copies and .omc', () => {
    assert.deepEqual(teamDirs(['a', 'a.bak', '.omc', 'b']), ['a', 'b']);
});

test('status --all --json scans the base, skips .bak/.omc/broken manifests; --all needs --json', async () => {
    const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = await import('fs');
    const { tmpdir } = await import('os');
    const { join } = await import('path');
    const { runStatus } = await import('../../src/commands/status.js');

    const base = mkdtempSync(join(tmpdir(), 'my-team-status-all-'));
    const write = (dir, body) => {
        mkdirSync(join(base, dir), { recursive: true });
        writeFileSync(join(base, dir, 'manifest.json'), body);
    };
    const m = (team) => JSON.stringify({
        team_name: team, state_root: join(base, team), session_name: `my-team-${team}-zz:0`,
        workers: [{ name: 'pm', pane_id: '%1', cwd: '/tmp' }],
    });
    write('alpha', m('alpha'));
    write('alpha.bak', m('alpha-bak'));
    write('.omc', m('omc'));
    write('broken', '{not json');
    mkdirSync(join(base, 'no-manifest'));

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    const out = [], err = [];
    const [log, error] = [console.log, console.error];
    console.log = (s) => out.push(String(s));
    console.error = (s) => err.push(String(s));
    try {
        await runStatus({ all: true, json: true });
        await assert.rejects(runStatus({ all: true }), /--all requires --json/);
    } finally {
        [console.log, console.error] = [log, error];
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
    const { teams } = JSON.parse(out.join('\n'));
    assert.deepEqual(teams.map((t) => t.team_name), ['alpha']);
    assert.equal(teams[0].team_alive, false);
    assert.equal(teams[0].workers[0].alive, false);
    assert.equal(err.length, 1);
    assert.match(err[0], /^skip broken:/);
});

test('listPanes: no tmux server means no panes; any other tmux failure is an error, not "nothing runs" (R2)', async () => {
    const { listPanes, runningByManifest } = await import('../../src/lib/team-liveness.js');
    // as child_process reports it: the message carries stderr too
    const fail = (stderr) => async () => { throw Object.assign(new Error(`Command failed: tmux list-panes\n${stderr}`), { stderr }); };
    assert.deepEqual(await listPanes(fail('no server running on /tmp/tmux-501/default\n')), []);
    assert.deepEqual(await listPanes(fail('error connecting to /tmp/mt.x/tmux-501/default (No such file or directory)\n')), []);
    await assert.rejects(listPanes(fail('lost server\n')), /lost server/);
    await assert.rejects(listPanes(async () => { throw Object.assign(new Error('spawn tmux ETIMEDOUT'), { stderr: '' }); }), /ETIMEDOUT/);
    const ok = async () => ({ stdout: '%1|pm|host\n' });   // PANE_FORMAT: pane id, @worker_name, session
    assert.deepEqual(await listPanes(ok), [{ session: 'host', paneId: '%1', worker: 'pm' }]);

    const { mkdtempSync, writeFileSync, rmSync } = await import('fs');
    const { tmpdir } = await import('os');
    const { join } = await import('path');
    const root = mkdtempSync(join(tmpdir(), 'my-team-r2-'));
    try {
        writeFileSync(join(root, 'manifest.json'), JSON.stringify({ session_name: 'host:0', workers: manifest.workers }));
        await assert.rejects(runningByManifest(root, () => listPanes(fail('lost server\n'))), /lost server/);
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});
