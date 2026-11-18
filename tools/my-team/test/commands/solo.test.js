/**
 * `my-team solo` (T141): a dev + reviewer board team in the current folder, built without a config file
 * and started through `start`.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { COPY_STEPS, runSolo, soloConfig, soloTeamName } from '../../src/commands/solo.js';
import { bashDenial } from '../../src/lib/worker-guard.js';
import { validateConfig } from '../../src/config/parser.js';
import { generateWorkerOverlay } from '../../src/lib/worker-bootstrap.js';

const BIN = fileURLToPath(new URL('../../bin/my-team', import.meta.url));

function folder(name) {
    const base = realpathSync(mkdtempSync(join(tmpdir(), 'my-team-solo-')));
    const cwd = join(base, name);
    mkdirSync(cwd);
    return { base, cwd };
}

/** `my-team solo <args>` in cwd with its own state base: the plan it prints, or the failure. */
function solo(cwd, base, args) {
    const r = spawnSync(process.execPath, [BIN, 'solo', '--dry-run', ...args], {
        cwd, encoding: 'utf-8', env: { ...process.env, MY_TEAM_STATE_ROOT_BASE: join(base, 'state') },
    });
    if (r.status !== 0) return { error: r.stderr };
    return JSON.parse(r.stdout.slice(r.stdout.indexOf('{')));
}

test('solo plans dev (orchestrator) and reviewer (worker) on a board, both with the arguments after --', () => {
    const { base, cwd } = folder('shop-api');
    try {
        const plan = solo(cwd, base, ['--', '--dangerously-skip-permissions', '--plugin-dir', '/some/plugins']);
        assert.equal(plan.team_name, 'solo-shop-api');
        assert.equal(plan.state_root, join(base, 'state', 'solo-shop-api'));
        assert.deepEqual(plan.board, { store: 'sqlite' });
        assert.deepEqual(plan.workers.map((w) => [w.name, w.role, w.cwd]),
            [['dev', 'orchestrator', cwd], ['reviewer', 'worker', cwd]]);
        for (const w of plan.workers) {
            assert.deepEqual(w.launch_args, ['--dangerously-skip-permissions', '--plugin-dir', '/some/plugins']);
            assert.equal(w.has_extra_prompt, true);
        }
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('solo without arguments after -- launches claude with none', () => {
    const { base, cwd } = folder('shop-api');
    try {
        for (const args of [[], ['--']]) {
            assert.deepEqual(solo(cwd, base, args).workers.map((w) => w.launch_args), [[], []]);
        }
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('solo --name names the team and its state folder; a name off the team name rule is refused', () => {
    const { base, cwd } = folder('shop-api');
    try {
        const plan = solo(cwd, base, ['--name', 'night-shift']);
        assert.equal(plan.team_name, 'night-shift');
        assert.equal(plan.state_root, join(base, 'state', 'night-shift'));
        assert.match(solo(cwd, base, ['--name', 'Night_Shift']).error, /Invalid team name/);
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('the default team name keeps only what the team name rule allows from the folder name', () => {
    assert.equal(soloTeamName('/w/My Repo.v2'), 'solo-my-repo-v2');
    assert.equal(soloTeamName('/w/__api__'), 'solo-api');
    const long = soloTeamName(`/w/${'a'.repeat(44)}-bcd`);
    assert.equal(long, `solo-${'a'.repeat(44)}`);
    assert.throws(() => soloTeamName('/w/작업'), /Pass --name/);
});

test('a folder name with nothing usable asks for --name', () => {
    const { base, cwd } = folder('작업');
    try {
        assert.match(solo(cwd, base, []).error, /Pass --name <team>/);
        assert.equal(solo(cwd, base, ['--name', 'work']).team_name, 'work');
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('solo is refused while a team of the same name runs, saying how to stop it', async () => {
    const { base, cwd } = folder('shop-api');
    const stateRoot = join(base, 'state', 'solo-shop-api');
    mkdirSync(stateRoot, { recursive: true });
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify({
        team_name: 'solo-shop-api', state_root: stateRoot, session_name: 'host:0', session_mode: 'split-pane',
        leader_pane: '%0', workers: [{ name: 'dev', pane_id: '%1' }, { name: 'reviewer', pane_id: '%2' }],
    }));
    const live = [{ session: 'host', paneId: '%0', worker: '' }, { session: 'host', paneId: '%1', worker: 'dev' }];
    const home = process.cwd();
    process.env.MY_TEAM_STATE_ROOT_BASE = join(base, 'state');
    process.chdir(cwd);
    try {
        await assert.rejects(runSolo([], { dryRun: true }, { listPanes: async () => live }),
            /Team 'solo-shop-api' is already running\. Use 'my-team shutdown --team solo-shop-api' first/);
    } finally {
        process.chdir(home);
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
});

/** Each worker's AGENTS.md as start writes it for this config. */
function overlays(raw) {
    const config = validateConfig(raw);
    const teamRoster = config.workers.map((w) => ({ name: w.name, agentType: w.agent_type, role: w.description, teamRole: w.role }));
    return Object.fromEntries(config.workers.map((w) => [w.name, generateWorkerOverlay({
        teamName: config.team_name, workerName: w.name, agentType: w.agent_type, workerRole: w.role,
        bootstrapInstructions: w.extra_prompt, instructionStateRoot: config.state_root, cwd: w.cwd, teamRoster,
        board: config.board, knowledge: config.knowledge, solo: config.solo,
    })]));
}

test('R1 L1, R1b S1: the solo reviewer copies the submitted commit with steps its repo-write rule lets through', () => {
    const { reviewer } = overlays(soloConfig({ cwd: tmpdir() }));
    for (const step of COPY_STEPS) assert.ok(reviewer.includes(step), step);

    // the steps as the reviewer runs them from the folder it shares with dev, the folder mktemp printed written out
    const repo = realpathSync(fileURLToPath(new URL('../../../../', import.meta.url)));
    const copy = realpathSync(mkdtempSync(join(tmpdir(), 'my-team-copy-')));
    const guard = (command) => bashDenial(command, ['push', 'repo-write'], { cwd: repo, repoRoot: repo });
    try {
        assert.equal(guard(`git archive HEAD | tar -x -C ${copy}`), null);
        assert.equal(guard(`cd ${copy}/tools/my-team && npm test`), null);
        // why the folder is written out: a git command on a variable's folder is not known to be outside the repository
        assert.notEqual(guard('D=$(mktemp -d); cd "$D" && git checkout HEAD'), null);
    } finally {
        rmSync(copy, { recursive: true, force: true });
    }
});

test('R1 L2: the solo dev is told to do the work itself, not to delegate or spread it', () => {
    const { dev } = overlays(soloConfig({ cwd: tmpdir() }));
    assert.match(dev, /## Team Role: ORCHESTRATOR \(solo\)/);
    assert.match(dev, /you do the work yourself: there is no worker to hand tickets to/);
    assert.doesNotMatch(dev, /Delegation discipline|Spread the work|delegate work to your workers/);
});

test('a team from a config file keeps the orchestrator guidance it had, solo false or absent', () => {
    const raw = { team_name: 'shop', board: { store: 'sqlite' }, workers: [
        { name: 'pm', agent_type: 'claude', cwd: tmpdir(), role: 'orchestrator' },
        { name: 'dev', agent_type: 'claude', cwd: tmpdir(), role: 'worker' }] };
    const absent = overlays(raw);
    assert.deepEqual(overlays({ ...raw, solo: false }), absent);
    assert.match(absent.pm, /## Team Role: ORCHESTRATOR\n[^\n]*delegate work to your workers/);
    assert.match(absent.pm, /Spread the work/);
    assert.doesNotMatch(absent.pm, /\(solo\)/);
    assert.throws(() => validateConfig({ ...raw, solo: 'yes' }), /solo must be true or false/);
});
