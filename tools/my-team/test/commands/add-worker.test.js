/**
 * Unit tests for `my-team add-worker` (mid-session worker add).
 *
 * Mirrors the send-message.test.js fixture pattern (mkdtemp state_root +
 * MY_TEAM_STATE_ROOT_BASE so loadManifest finds the manifest by team name),
 * but with a 5-field manifest worker shape {name, pane_id, cwd, agent_type,
 * overlay_path} — the shape start.js actually writes and add-worker appends to.
 *
 * No real tmux session exists in tests, so the tmux-touching functions
 * (isWorkerAlive / addWorkerPane / spawnWorkerInPane / waitForPaneReady /
 * sendToWorker / killPane) are injected via runAddWorker's `deps` seam. The
 * disk side (ensureWorkerStateDir / generateWorkerOverlay / writeFile /
 * atomicWriteJson / loadManifest) runs for real against the mkdtemp dir and is
 * asserted on disk.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'fs';
import { tmpdir, homedir } from 'os';
import { join } from 'path';
import { execFileSync } from 'child_process';

import { runAddWorker } from '../../src/commands/add-worker.js';
import { stripSessionArgs } from '../../src/commands/start.js';

/** A real, existing dir to use as a valid --cwd (the worker's cwd must exist). */
const VALID_CWD = tmpdir();

/**
 * add-worker refuses a --cwd an existing worker already uses, so fixture
 * workers must NOT sit on VALID_CWD (the dir the new worker asks for).
 * stateRoot is real, unique per fixture, and irrelevant to the assertions.
 */
function fixtureWorkerCwd(stateRoot) {
    return stateRoot;
}

function setupTeam({ teamName = 't1', workers = ['alice', 'bob'] } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(stateRoot, { recursive: true });
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });

    const manifest = {
        team_name: teamName,
        state_root: stateRoot,
        session_name: 'test-session',
        session_mode: 'split-pane',
        leader_pane: '%0',
        workers: workers.map((w, i) => {
            // Accept either a bare name (legacy peer team) or {name, role}
            // so a test can build a role-declaring team.
            const { name, role } = typeof w === 'string' ? { name: w, role: undefined } : w;
            const entry = {
                name,
                pane_id: `%${i + 1}`,
                cwd: fixtureWorkerCwd(stateRoot),
                agent_type: 'claude',
                overlay_path: '',
            };
            if (role !== undefined) entry.role = role;
            return entry;
        }),
    };
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify(manifest), 'utf-8');

    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    delete process.env.MY_TEAM_STATE_ROOT;
    rmSync(ctx.base, { recursive: true, force: true });
}

function readManifest(ctx) {
    return JSON.parse(readFileSync(join(ctx.stateRoot, 'manifest.json'), 'utf-8'));
}

/** Default tmux stubs: everything succeeds, new pane id is %9. */
function okDeps(overrides = {}) {
    return {
        isWorkerAlive: async () => true,
        addWorkerPane: async () => ({ paneId: '%9' }),
        spawnWorkerInPane: async () => {},
        waitForPaneReady: async () => true,
        sendToWorker: async () => true,
        killPane: async () => {},
        ...overrides,
    };
}

const validOpts = (over = {}) => ({
    team: 't1', name: 'carol', cwd: VALID_CWD, agentType: 'claude', ...over,
});

// ── Step 1: required-flag gates (no manifest needed for the first ones) ──

test('rejects missing --team', async () => {
    await assert.rejects(
        () => runAddWorker({}, okDeps()),
        /team/i
    );
});

test('rejects missing --name', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(() => runAddWorker({ team: 't1' }, okDeps()), /name/i);
    } finally { cleanup(ctx); }
});

test('rejects missing --cwd', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(() => runAddWorker({ team: 't1', name: 'carol' }, okDeps()), /cwd/i);
    } finally { cleanup(ctx); }
});

test('rejects missing --agent-type', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runAddWorker({ team: 't1', name: 'carol', cwd: VALID_CWD }, okDeps()),
            /agent/i
        );
    } finally { cleanup(ctx); }
});

// ── Step 1: manifest / membership / cap gates ──

test('rejects when team manifest is missing (team not running)', async () => {
    // No setupTeam → no manifest on disk. Point base at an empty temp dir.
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    try {
        await assert.rejects(() => runAddWorker(validOpts(), okDeps()), /running|not found|manifest/i);
    } finally {
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        rmSync(base, { recursive: true, force: true });
    }
});

test('rejects duplicate worker name (raw)', async () => {
    const ctx = setupTeam({ workers: ['alice', 'bob'] });
    try {
        await assert.rejects(() => runAddWorker(validOpts({ name: 'alice' }), okDeps()), /duplicate|alice/i);
    } finally { cleanup(ctx); }
});

test('rejects sanitized name collision (50-char truncation)', async () => {
    // Two names that differ only past the 50-char sanitize cap collide.
    const prefix = 'a'.repeat(50);
    const existing = prefix + 'XXXX';
    const incoming = prefix + 'YYYY';
    const ctx = setupTeam({ workers: [existing] });
    try {
        await assert.rejects(
            () => runAddWorker(validOpts({ name: incoming }), okDeps()),
            /collision|saniti/i
        );
    } finally { cleanup(ctx); }
});

// ── --team accepts a tmux session name, not just the team name ──

test('resolves --team given a tmux session name (with :window suffix)', async () => {
    // The fixture session_name is 'test-session'; pass it (with a :0 suffix, as
    // a manifest stores it) as --team and confirm it resolves to team t1: the
    // worker is appended and the greeting embeds the t1 overlay path.
    const ctx = setupTeam({ workers: ['alice'] });
    const notices = [];
    try {
        const deps = okDeps({
            sendToWorker: async (_s, paneId, msg) => { notices.push({ paneId, msg }); return true; },
        });
        await runAddWorker(validOpts({ team: 'test-session:0' }), deps);
        const m = readManifest(ctx);
        assert.ok(m.workers.some((w) => w.name === 'carol'), 'worker appended via session-name resolve');
        // Canonical team name (t1) — not the session name — drives the overlay path.
        const expectedOverlay = join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md');
        assert.ok(notices[0]?.msg.includes(expectedOverlay), 'greeting uses canonical-team overlay path');
    } finally { cleanup(ctx); }
});

test('errors clearly when --team matches no team dir and no session name', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    try {
        await assert.rejects(
            () => runAddWorker(validOpts({ team: 'my-team-nope-deadbeef' }), okDeps()),
            /No team matched|running/i
        );
    } finally { cleanup(ctx); }
});

test('rejects when cap (10 workers) would be exceeded', async () => {
    const ten = Array.from({ length: 10 }, (_, i) => `w${i}`);
    const ctx = setupTeam({ workers: ten });
    try {
        await assert.rejects(() => runAddWorker(validOpts(), okDeps()), /10|cap|exceed/i);
    } finally { cleanup(ctx); }
});

test('rejects non-existent --cwd (via validateWorker)', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runAddWorker(validOpts({ cwd: '/no/such/path/at/all' }), okDeps()),
            /exist|director/i
        );
    } finally { cleanup(ctx); }
});

// ── Success + disk assertions ──

test('success: appends 5-field entry to manifest on disk', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    try {
        const res = await runAddWorker(validOpts(), okDeps());
        const m = readManifest(ctx);
        const carol = m.workers.find((w) => w.name === 'carol');
        assert.ok(carol, 'carol appended to manifest');
        assert.equal(carol.pane_id, '%9');
        assert.equal(carol.cwd, VALID_CWD);
        assert.equal(carol.agent_type, 'claude');
        assert.equal(typeof carol.overlay_path, 'string');
        assert.ok(carol.overlay_path.length > 0, 'overlay_path is set');
        // existing worker untouched
        assert.ok(m.workers.find((w) => w.name === 'alice'), 'alice still present');
        // return value
        assert.equal(res.name, 'carol');
        assert.equal(res.pane_id, '%9');
    } finally { cleanup(ctx); }
});

test('success: writes new worker AGENTS.md containing the new roster', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    try {
        await runAddWorker(validOpts(), okDeps());
        const overlay = join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md');
        assert.ok(existsSync(overlay), 'carol AGENTS.md written');
        const body = readFileSync(overlay, 'utf-8');
        assert.match(body, /carol/, 'roster lists self');
        assert.match(body, /alice/, 'roster lists existing peer');
    } finally { cleanup(ctx); }
});

test('a board team\'s new worker gets the board section; a team without a board does not (T63g)', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    try {
        const m = readManifest(ctx);
        m.board = { store: 'sqlite' };
        writeFileSync(join(ctx.stateRoot, 'manifest.json'), JSON.stringify(m), 'utf-8');
        await runAddWorker(validOpts(), okDeps());
        assert.match(readFileSync(join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md'), 'utf-8'), /## Team Board/);
        assert.deepEqual(readManifest(ctx).board, { store: 'sqlite' }, 'the manifest keeps its board');
    } finally { cleanup(ctx); }
    const plain = setupTeam({ workers: ['alice'] });
    try {
        await runAddWorker(validOpts(), okDeps());
        assert.doesNotMatch(readFileSync(join(plain.stateRoot, 'workers', 'carol', 'AGENTS.md'), 'utf-8'), /Team Board|board-/);
    } finally { cleanup(plain); }
});

test('does NOT rewrite existing workers\' AGENTS.md (decision §0 #1)', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    try {
        // pre-seed alice's overlay with a marker
        const aliceDir = join(ctx.stateRoot, 'workers', 'alice');
        mkdirSync(aliceDir, { recursive: true });
        const aliceOverlay = join(aliceDir, 'AGENTS.md');
        writeFileSync(aliceOverlay, 'MARKER-DO-NOT-TOUCH', 'utf-8');

        await runAddWorker(validOpts(), okDeps());

        assert.equal(readFileSync(aliceOverlay, 'utf-8'), 'MARKER-DO-NOT-TOUCH',
            'existing worker overlay must be unchanged');
    } finally { cleanup(ctx); }
});

test('rollback: spawn failure kills the new pane and does NOT append manifest', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    let killed = null;
    try {
        const deps = okDeps({
            spawnWorkerInPane: async () => { throw new Error('boom'); },
            killPane: async (id) => { killed = id; },
        });
        await assert.rejects(() => runAddWorker(validOpts(), deps), /boom/);
        assert.equal(killed, '%9', 'new pane was killed on rollback');
        const m = readManifest(ctx);
        assert.equal(m.workers.find((w) => w.name === 'carol'), undefined,
            'manifest must NOT contain carol after rollback');
    } finally { cleanup(ctx); }
});

// ── Name pattern boundary ──

test('rejects name with invalid characters (underscore)', async () => {
    const ctx = setupTeam();
    try {
        await assert.rejects(
            () => runAddWorker(validOpts({ name: 'alice_bob' }), okDeps()),
            /match|pattern|name/i
        );
    } finally { cleanup(ctx); }
});

// ── Liveness gate (also guards against the async-.find anchor trap) ──

test('rejects when no worker pane is alive (team session not live)', async () => {
    const ctx = setupTeam({ workers: ['alice', 'bob'] });
    try {
        const deps = okDeps({ isWorkerAlive: async () => false });
        await assert.rejects(() => runAddWorker(validOpts(), deps), /not live|session/i);
    } finally { cleanup(ctx); }
});

test('anchors on the first ALIVE worker when an earlier pane is dead', async () => {
    // workers[0]=alice is dead, workers[1]=bob is alive. add-worker must still
    // succeed, anchoring the split on bob's pane (%2), not the dead alice (%1).
    const ctx = setupTeam({ workers: ['alice', 'bob'] });
    let splitAnchor = null;
    try {
        const deps = okDeps({
            isWorkerAlive: async (paneId) => paneId !== '%1', // alice (%1) dead, bob (%2) alive
            addWorkerPane: async (_session, anchorPaneId) => { splitAnchor = anchorPaneId; return { paneId: '%9' }; },
        });
        await runAddWorker(validOpts(), deps);
        assert.equal(splitAnchor, '%2', 'split must anchor on the alive worker (bob), not the dead one');
    } finally { cleanup(ctx); }
});

// ── Shared-cwd guard: two workers in one working tree overwrite each other ──

test('refuses a --cwd an existing worker already uses, before any side effect', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    // Put alice on the very dir carol will ask for.
    const m = readManifest(ctx);
    m.workers[0].cwd = VALID_CWD;
    writeFileSync(join(ctx.stateRoot, 'manifest.json'), JSON.stringify(m), 'utf-8');
    let split = false;
    try {
        const deps = okDeps({ addWorkerPane: async () => { split = true; return { paneId: '%9' }; } });
        await assert.rejects(
            () => runAddWorker(validOpts(), deps),
            /already used by 'alice'.*--worktree/s
        );
        assert.equal(split, false, 'refused before the pane split — no side effect');
        assert.equal(readManifest(ctx).workers.length, 1, 'manifest untouched');
        assert.ok(!existsSync(join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md')), 'no overlay written');
    } finally { cleanup(ctx); }
});

test('the shared-cwd guard compares canonical paths (tilde, trailing slash)', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    const m = readManifest(ctx);
    m.workers[0].cwd = homedir();
    writeFileSync(join(ctx.stateRoot, 'manifest.json'), JSON.stringify(m), 'utf-8');
    try {
        // `~` and `<home>/` must both resolve onto alice's plain homedir().
        await assert.rejects(() => runAddWorker(validOpts({ cwd: '~' }), okDeps()), /already used by 'alice'/);
        await assert.rejects(() => runAddWorker(validOpts({ cwd: `${homedir()}/` }), okDeps()), /already used by 'alice'/);
    } finally { cleanup(ctx); }
});

test('--allow-shared-cwd overrides the guard', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    const m = readManifest(ctx);
    m.workers[0].cwd = VALID_CWD;
    writeFileSync(join(ctx.stateRoot, 'manifest.json'), JSON.stringify(m), 'utf-8');
    try {
        await runAddWorker(validOpts({ allowSharedCwd: true }), okDeps());
        const names = readManifest(ctx).workers.map((w) => w.name);
        assert.deepEqual(names, ['alice', 'carol']);
    } finally { cleanup(ctx); }
});

test('--worktree bypasses the guard: the worker lands in its own working tree', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    const repo = mkdtempSync(join(tmpdir(), 'my-team-repo-'));
    execFileSync('git', ['-C', repo, 'init', '-q']);
    execFileSync('git', ['-C', repo, 'commit', '-q', '--allow-empty', '-m', 'init']);
    // alice already occupies the repo root — without --worktree this is refused.
    const m = readManifest(ctx);
    m.workers[0].cwd = repo;
    writeFileSync(join(ctx.stateRoot, 'manifest.json'), JSON.stringify(m), 'utf-8');
    try {
        await runAddWorker(validOpts({ cwd: repo, worktree: 'feature-x' }), okDeps());
        const carol = readManifest(ctx).workers.find((w) => w.name === 'carol');
        // git reports the resolved path (/private/var vs /var on macOS), so
        // compare through realpath rather than string-equal on `repo`.
        assert.equal(realpathSync(carol.cwd), join(realpathSync(repo), '.worktrees', 'carol'),
            'carol got her own working tree');
        assert.notEqual(realpathSync(carol.cwd), realpathSync(m.workers[0].cwd),
            'not the dir alice occupies');
    } finally {
        rmSync(repo, { recursive: true, force: true });
        cleanup(ctx);
    }
});

// ── Join notice: D reports in to the orchestrator only; peers are untouched ──

test('in a role team, the join notice tells the newcomer to report in to the orchestrator only', async () => {
    const ctx = setupTeam({ workers: [{ name: 'alice', role: 'orchestrator' }, { name: 'bob', role: 'worker' }] });
    const notices = [];
    try {
        const deps = okDeps({
            sendToWorker: async (_session, paneId, msg) => { notices.push({ paneId, msg }); return true; },
        });
        await runAddWorker(validOpts(), deps);
        // The ONLY sendToWorker call targets the new pane (%9). Existing panes
        // are never poked — peers learn of the newcomer via mailbox-list roster.
        assert.equal(notices.length, 1, 'exactly one notice — to the new pane only');
        assert.equal(notices[0].paneId, '%9', 'notice targets the new worker pane');
        assert.match(notices[0].msg, /alice/, 'the newcomer is pointed at the orchestrator by name');
        assert.doesNotMatch(notices[0].msg, /bob/, 'non-orchestrator peers are not named as recipients');
        // The greeting-to-everyone behaviour is gone: the notice must say the
        // report-in is one-way, not request an ack from every peer.
        assert.match(notices[0].msg, /no expects_reply/, 'report-in is explicitly one-way, no ack storm');
        assert.match(notices[0].msg, /Do not message any other worker/i, 'no fan-out to peers');
        assert.match(notices[0].msg, /cwd/, 'report-in carries cwd so the orchestrator can narrate the join');
        assert.doesNotMatch(notices[0].msg, /files\/dirs you expect to touch/,
            'file scope is NOT reported — worktrees keep working trees separate');
        // The notice MUST carry the absolute overlay path. The worker boots in
        // its own cwd with nothing wiring the overlay in, so a bare "your
        // AGENTS.md" leaves it unable to find its roster (the bug this fixes).
        const expectedOverlay = join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md');
        assert.ok(
            notices[0].msg.includes(expectedOverlay),
            `notice must embed the absolute overlay path (${expectedOverlay})`
        );
    } finally { cleanup(ctx); }
});

test('in a peer team (no roles) the newcomer is told NOT to introduce itself', async () => {
    const ctx = setupTeam({ workers: ['alice', 'bob'] });
    const notices = [];
    try {
        const deps = okDeps({
            sendToWorker: async (_session, paneId, msg) => { notices.push({ paneId, msg }); return true; },
        });
        await runAddWorker(validOpts(), deps);
        assert.equal(notices.length, 1, 'still exactly one notice — to the new pane only');
        assert.equal(notices[0].paneId, '%9');
        assert.match(notices[0].msg, /Do not introduce yourself/i, 'no peer greeting in a roleless team');
        assert.doesNotMatch(notices[0].msg, /expects_reply/, 'no ack storm');
        assert.match(notices[0].msg, /roster/, 'peers learn of it through the roster instead');
        const existingPanes = notices.filter((n) => n.paneId === '%1' || n.paneId === '%2');
        assert.equal(existingPanes.length, 0, 'existing worker panes are NOT poked in-pane');
    } finally { cleanup(ctx); }
});

// ── Reload-ENOENT mid-operation abort (decision §0 #3) ──

test('aborts + kills pane if manifest disappears before the commit-point reload', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    let killed = null;
    try {
        const deps = okDeps({
            killPane: async (id) => { killed = id; },
            // simulate a concurrent shutdown: remove the manifest after the pane is split
            addWorkerPane: async () => {
                rmSync(join(ctx.stateRoot, 'manifest.json'), { force: true });
                return { paneId: '%9' };
            },
        });
        await assert.rejects(() => runAddWorker(validOpts(), deps), /shut down|mid-operation|manifest/i);
        assert.equal(killed, '%9', 'orphan pane killed on mid-operation abort');
    } finally { cleanup(ctx); }
});

// ── Tilde cwd expansion (validateWorker's expanded path must be used) ──

test('expands ~ in --cwd before storing in manifest and splitting the pane', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    let splitCwd = null;
    try {
        const deps = okDeps({
            addWorkerPane: async (_session, _anchor, worker) => { splitCwd = worker.cwd; return { paneId: '%9' }; },
        });
        // ~ always exists; validateWorker expands it to homedir()
        await runAddWorker(validOpts({ cwd: '~' }), deps);
        assert.equal(splitCwd, homedir(), 'pane split must use the expanded cwd, not "~"');
        const carol = readManifest(ctx).workers.find((w) => w.name === 'carol');
        assert.equal(carol.cwd, homedir(), 'manifest must store the expanded cwd, not "~"');
    } finally { cleanup(ctx); }
});

// ── launch_args forwarding (--launch-arg) ──

test('forwards launchArgs to the spawned worker CLI', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    let spawned = null;
    try {
        const deps = okDeps({
            spawnWorkerInPane: async (_session, _pane, config) => { spawned = config; },
        });
        await runAddWorker(validOpts({ launchArgs: ['--dangerously-skip-permissions'] }), deps);
        assert.deepEqual(spawned.launchArgs, ['--dangerously-skip-permissions'],
            'launch args must reach the spawned CLI');
    } finally { cleanup(ctx); }
});

test('defaults launchArgs to empty array when not provided', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    let spawned = null;
    try {
        const deps = okDeps({
            spawnWorkerInPane: async (_session, _pane, config) => { spawned = config; },
        });
        await runAddWorker(validOpts(), deps);
        assert.deepEqual(spawned.launchArgs, [], 'launchArgs defaults to []');
    } finally { cleanup(ctx); }
});

test('--description is persisted in the manifest and existing peers\' descriptions reach the new roster', async () => {
    const ctx = setupTeam();
    try {
        // start.js persisted alice's description; add-worker must render it.
        const manifestPath = join(ctx.stateRoot, 'manifest.json');
        const m = JSON.parse(readFileSync(manifestPath, 'utf-8'));
        m.workers[0].description = 'alice owns the API';
        writeFileSync(manifestPath, JSON.stringify(m), 'utf-8');

        await runAddWorker(validOpts({ description: 'carol reviews PRs' }), okDeps());

        const carol = readManifest(ctx).workers.find((w) => w.name === 'carol');
        assert.equal(carol.description, 'carol reviews PRs');

        const body = readFileSync(join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md'), 'utf-8');
        assert.match(body, /\*\*alice\*\* \[claude\] — alice owns the API/, 'peer description from manifest');
        assert.match(body, /\*\*carol\*\* \(you\) \[claude\] — carol reviews PRs/);
    } finally {
        cleanup(ctx);
    }
});

test('--description is stored as one line, like start does', async () => {
    const ctx = setupTeam();
    try {
        await runAddWorker(validOpts({ description: 'first line\nsecond line' }), okDeps());
        assert.equal(readManifest(ctx).workers.find((w) => w.name === 'carol').description, 'first line');
    } finally {
        cleanup(ctx);
    }
});

// ── --worktree: real git repo in tmp, tmux still stubbed ──
import { execSync } from 'child_process';
import { realpathSync } from 'fs';

function makeRepo() {
    // realpath: macOS tmpdir is a symlink (/var → /private/var) and git reports the resolved path.
    const repo = realpathSync(mkdtempSync(join(tmpdir(), 'my-team-repo-')));
    execSync('git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init', { cwd: repo });
    return repo;
}
const git = (cwd, args) => execSync(`git ${args}`, { cwd, encoding: 'utf-8' }).trim();

test('--worktree creates <repo>/.worktrees/<name> on a new branch and boots the worker there', async () => {
    const ctx = setupTeam();
    const repo = makeRepo();
    try {
        let paneCwd;
        await runAddWorker(
            validOpts({ cwd: repo, worktree: 'feat-cart' }),
            okDeps({ addWorkerPane: async (_s, _anchor, w) => { paneCwd = w.cwd; return { paneId: '%9' }; } })
        );
        const wt = join(repo, '.worktrees', 'carol');
        assert.equal(paneCwd, wt, 'pane opens in the worktree');
        const carol = readManifest(ctx).workers.find((w) => w.name === 'carol');
        assert.equal(carol.cwd, wt);
        assert.equal(git(wt, 'rev-parse --abbrev-ref HEAD'), 'feat-cart');
        assert.match(carol.description, /feat-cart/, 'roster one-liner names the branch when --description is omitted');
        assert.match(readFileSync(join(repo, '.git', 'info', 'exclude'), 'utf-8'), /^\.worktrees\/$/m,
            'worktree dir is excluded locally so git status of the main checkout stays clean');
    } finally {
        cleanup(ctx);
        rmSync(repo, { recursive: true, force: true });
    }
});

test('--worktree checks out an existing branch instead of failing on -b', async () => {
    const ctx = setupTeam();
    const repo = makeRepo();
    try {
        git(repo, 'branch feat-old');
        await runAddWorker(validOpts({ cwd: repo, worktree: 'feat-old' }), okDeps());
        assert.equal(git(join(repo, '.worktrees', 'carol'), 'rev-parse --abbrev-ref HEAD'), 'feat-old');
    } finally {
        cleanup(ctx);
        rmSync(repo, { recursive: true, force: true });
    }
});

test('--worktree rejects a --cwd that is not a git repo before any pane is split', async () => {
    const ctx = setupTeam();
    const plain = mkdtempSync(join(tmpdir(), 'my-team-plain-'));
    try {
        let split = false;
        await assert.rejects(
            () => runAddWorker(validOpts({ cwd: plain, worktree: 'x' }), okDeps({ addWorkerPane: async () => { split = true; return { paneId: '%9' }; } })),
            /not a git repository/i
        );
        assert.equal(split, false);
        assert.equal(existsSync(join(plain, '.worktrees')), false);
    } finally {
        cleanup(ctx);
        rmSync(plain, { recursive: true, force: true });
    }
});

test('--worktree removes the worktree it just created when a later step fails', async () => {
    const ctx = setupTeam();
    const repo = makeRepo();
    try {
        await assert.rejects(
            () => runAddWorker(validOpts({ cwd: repo, worktree: 'feat-x' }), okDeps({ addWorkerPane: async () => { throw new Error('split failed'); } })),
            /split failed/
        );
        assert.equal(existsSync(join(repo, '.worktrees', 'carol')), false, 'worktree dir removed');
        assert.doesNotMatch(git(repo, 'worktree list'), /\.worktrees\/carol/, 'git no longer tracks it');
    } finally {
        cleanup(ctx);
        rmSync(repo, { recursive: true, force: true });
    }
});

test('inherits launch_args from the calling worker (MY_TEAM_WORKER) when --launch-arg is omitted', async () => {
    const ctx = setupTeam();
    try {
        const manifestPath = join(ctx.stateRoot, 'manifest.json');
        const m = JSON.parse(readFileSync(manifestPath, 'utf-8'));
        m.workers[0].launch_args = ['--dangerously-skip-permissions'];
        writeFileSync(manifestPath, JSON.stringify(m), 'utf-8');
        process.env.MY_TEAM_WORKER = 't1/alice';

        let spawned;
        await runAddWorker(validOpts(), okDeps({ spawnWorkerInPane: async (_s, _p, config) => { spawned = config; } }));
        assert.deepEqual(spawned.launchArgs, ['--dangerously-skip-permissions'], 'a worker-spawned peer must not stall on permission prompts');
        assert.deepEqual(readManifest(ctx).workers.find((w) => w.name === 'carol').launch_args, ['--dangerously-skip-permissions'],
            'persisted so the next add-worker can inherit again');
    } finally {
        delete process.env.MY_TEAM_WORKER;
        cleanup(ctx);
    }
});

test('--worktree: a failure AFTER the pane split kills the pane and removes the worktree', async () => {
    const ctx = setupTeam();
    const repo = makeRepo();
    try {
        const killed = [];
        await assert.rejects(
            () => runAddWorker(validOpts({ cwd: repo, worktree: 'feat-x' }), okDeps({
                spawnWorkerInPane: async () => { throw new Error('spawn failed'); },
                killPane: async (id) => { killed.push(id); },
            })),
            /spawn failed/
        );
        assert.deepEqual(killed, ['%9'], 'orphan pane killed');
        assert.equal(existsSync(join(repo, '.worktrees', 'carol')), false, 'worktree removed');
        assert.equal(readManifest(ctx).workers.length, 2, 'manifest untouched');
    } finally {
        cleanup(ctx);
        rmSync(repo, { recursive: true, force: true });
    }
});

test('--extra-prompt renders into the new worker\'s AGENTS.md Role Context', async () => {
    const ctx = setupTeam();
    try {
        await runAddWorker(validOpts({ extraPrompt: '## 목적\n주문 API 구현' }), okDeps());
        const body = readFileSync(join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md'), 'utf-8');
        assert.match(body, /## Role Context\n## 목적\n주문 API 구현/, 'extra prompt lands in Role Context');
    } finally { cleanup(ctx); }
});

test('without --extra-prompt the new worker\'s AGENTS.md has no Role Context section', async () => {
    const ctx = setupTeam();
    try {
        await runAddWorker(validOpts(), okDeps());
        const body = readFileSync(join(ctx.stateRoot, 'workers', 'carol', 'AGENTS.md'), 'utf-8');
        assert.doesNotMatch(body, /^## Role Context/m);
    } finally { cleanup(ctx); }
});

test('stripSessionArgs drops claude session-binding args and keeps the rest', () => {
    assert.deepEqual(
        stripSessionArgs(['--dangerously-skip-permissions', '--resume', 'sid-a', '-r', 'sid-b', '--resume=sid-c',
            '--session-id', 'sid-d', '--continue', '-c', '--fork-session', '--model', 'opus'], 'claude'),
        ['--dangerously-skip-permissions', '--model', 'opus'],
    );
    assert.deepEqual(stripSessionArgs(['--resume', '--verbose'], 'claude'), ['--verbose'], 'bare --resume (picker) does not eat the next flag');
    // codex `-c <key=value>` is a config flag, not claude's --continue
    assert.deepEqual(stripSessionArgs(['-c', 'model_reasoning_effort=high'], 'codex'), ['-c', 'model_reasoning_effort=high']);
});

test('does not inherit or persist the caller\'s --resume <sid> (a peer must not open the caller\'s session)', async () => {
    const ctx = setupTeam();
    try {
        const manifestPath = join(ctx.stateRoot, 'manifest.json');
        const m = JSON.parse(readFileSync(manifestPath, 'utf-8'));
        m.workers[0].launch_args = ['--dangerously-skip-permissions', '--resume', 'alice-sid'];
        writeFileSync(manifestPath, JSON.stringify(m), 'utf-8');
        process.env.MY_TEAM_WORKER = 't1/alice';

        let spawned;
        await runAddWorker(validOpts(), okDeps({ spawnWorkerInPane: async (_s, _p, config) => { spawned = config; } }));
        assert.deepEqual(spawned.launchArgs, ['--dangerously-skip-permissions']);
        assert.deepEqual(readManifest(ctx).workers.find((w) => w.name === 'carol').launch_args, ['--dangerously-skip-permissions']);
    } finally {
        delete process.env.MY_TEAM_WORKER;
        cleanup(ctx);
    }
});

// ── deny rules (T59): a hook installed by --settings, not inherited, not in the manifest ──

test('--deny installs the guard hook for this worker only: --settings at launch, not in the manifest (T59 e)', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    let spawned = null;
    try {
        const deps = okDeps({ spawnWorkerInPane: async (_s, _p, config) => { spawned = config; } });
        await runAddWorker(validOpts({ deny: 'push,repo-write', launchArgs: ['--model', 'haiku'] }), deps);
        const settings = join(ctx.stateRoot, 'workers', 'carol', 'guard-settings.json');
        assert.deepEqual(spawned.launchArgs, ['--model', 'haiku', '--settings', settings]);
        assert.match(readFileSync(settings, 'utf-8'), /--deny 'push,repo-write'/);
        const carol = readManifest(ctx).workers.find((w) => w.name === 'carol');
        assert.deepEqual(carol.launch_args, ['--model', 'haiku'], 'a peer inheriting these flags does not inherit the rules');
    } finally { cleanup(ctx); }
});

test('without --deny no hook is installed (T59 d)', async () => {
    const ctx = setupTeam({ workers: ['alice'] });
    let spawned = null;
    try {
        const deps = okDeps({ spawnWorkerInPane: async (_s, _p, config) => { spawned = config; } });
        await runAddWorker(validOpts(), deps);
        assert.equal(spawned.launchArgs.includes('--settings'), false);
        assert.equal(existsSync(join(ctx.stateRoot, 'workers', 'carol', 'guard-settings.json')), false);
        await assert.rejects(runAddWorker(validOpts({ name: 'dave', deny: 'force-push', allowSharedCwd: true }), deps), /deny/);
    } finally { cleanup(ctx); }
});
