/**
 * A team's state_root across runs (T51): `shutdown` only ends the tmux side and
 * leaves state_root as it is; `start` begins a new team, moving a previous
 * state_root to <state_root>.<timestamp>.bak; `start --continue` keeps it,
 * so mail, work files and events carry over. isSafeToWipe guards the move.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync, readdirSync, rmSync, chmodSync } from 'fs';
import { tmpdir, homedir } from 'os';
import { join, dirname, basename } from 'path';

import { createSqliteStore } from '../../src/board/store/sqlite/index.js';

import { isSafeToWipe, backupAndRemoveStateRoot, backupPathFor, prepareStateRoot, unfinishedBoardSummary, runStart } from '../../src/commands/start.js';
import { runShutdown } from '../../src/commands/shutdown.js';

const sqlite = await import('node:sqlite').catch(() => null);
const needsSqlite = sqlite ? {} : { skip: 'node:sqlite needs Node >= 22.13' };

/** The timestamped backups of `stateRoot`, oldest name first. */
const backups = (stateRoot) => readdirSync(dirname(stateRoot))
    .filter((n) => n.startsWith(`${basename(stateRoot)}.`) && n.endsWith('.bak')).sort().map((n) => join(dirname(stateRoot), n));

const MAIL = '{"schema_version":2,"messages":[{"message_id":"m1","body":"not delivered yet"}]}';

function makeStateRoot() {
    // mkdtemp gives a deep, unique path (e.g. /var/folders/.../my-team-XXXX),
    // which is what a real session state_root looks like — safe to wipe.
    const base = mkdtempSync(join(tmpdir(), 'my-team-shutdown-'));
    const stateRoot = join(base, 'demo-team');
    mkdirSync(join(stateRoot, 'archive'), { recursive: true });
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
    writeFileSync(join(stateRoot, 'manifest.json'), '{"team_name":"demo-team"}', 'utf-8');
    writeFileSync(join(stateRoot, 'events.jsonl'), '{"ts":"run-1"}\n', 'utf-8');
    writeFileSync(join(stateRoot, 'archive', 'alice.jsonl'), '{"m":1}\n', 'utf-8');
    writeFileSync(join(stateRoot, 'mailbox', 'alice.json'), MAIL, 'utf-8');
    mkdirSync(join(stateRoot, 'work'), { recursive: true });
    writeFileSync(join(stateRoot, 'work', 'notes.md'), 'half done\n', 'utf-8');
    return { base, stateRoot };
}

test('isSafeToWipe rejects dangerous / shallow paths', () => {
    assert.equal(isSafeToWipe(''), false);
    assert.equal(isSafeToWipe(null), false);
    assert.equal(isSafeToWipe(undefined), false);
    assert.equal(isSafeToWipe('/'), false);
    assert.equal(isSafeToWipe(homedir()), false);
    assert.equal(isSafeToWipe(homedir() + '/'), false); // trailing slash normalized
    assert.equal(isSafeToWipe('/tmp'), false);          // 1 segment — too shallow
    assert.equal(isSafeToWipe('/var/tmp'), false);      // 2 segments — too shallow
});

test('isSafeToWipe accepts a deep session state_root', () => {
    assert.equal(isSafeToWipe('/Users/me/.my-team/sessions/demo'), true);
    assert.equal(isSafeToWipe('/a/b/c'), true); // exactly 3 segments — the floor
});

test('backupAndRemoveStateRoot moves state_root to a timestamped .bak and clears original', async () => {
    const { base, stateRoot } = makeStateRoot();
    try {
        const res = await backupAndRemoveStateRoot(stateRoot);
        const bak = res.backedUpTo;

        assert.match(bak, new RegExp(`^${stateRoot}\\.\\d{8}-\\d{9}(-\\d+)?\\.bak$`));
        assert.deepEqual(backups(stateRoot), [bak]);
        assert.equal(existsSync(stateRoot), false, 'original removed');
        assert.equal(existsSync(bak), true, 'backup exists');
        // Content preserved in the backup.
        assert.equal(readFileSync(join(bak, 'events.jsonl'), 'utf-8'), '{"ts":"run-1"}\n');
        assert.equal(existsSync(join(bak, 'archive', 'alice.jsonl')), true);
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('backupAndRemoveStateRoot preserves state when the backup rename fails', async (t) => {
    // The user opted to always keep a backup, so a failed rename must NEVER
    // delete the original. Force rename to fail by making the parent dir
    // read-only (EACCES on rename). Skipped when running as root (perms ignored).
    if (typeof process.getuid === 'function' && process.getuid() === 0) {
        t.skip('cannot test EACCES as root');
        return;
    }
    const { base, stateRoot } = makeStateRoot();
    const parent = join(base); // base is the parent of stateRoot
    try {
        chmodSync(parent, 0o500); // r-x: cannot create/rename entries inside
        const res = await backupAndRemoveStateRoot(stateRoot);

        assert.equal(res.backedUpTo, null, 'reports failure');
        assert.ok(res.error, 'carries the underlying error');
        assert.equal(existsSync(stateRoot), true, 'original state preserved (no data loss)');
    } finally {
        chmodSync(parent, 0o700); // restore so cleanup can remove it
        rmSync(base, { recursive: true, force: true });
    }
});

test('a second backup keeps the first one (and a leftover plain .bak)', async () => {
    const { base, stateRoot } = makeStateRoot();
    try {
        mkdirSync(`${stateRoot}.bak`, { recursive: true });
        writeFileSync(join(`${stateRoot}.bak`, 'events.jsonl'), '{"ts":"OLD-stale"}\n', 'utf-8');

        const first = (await backupAndRemoveStateRoot(stateRoot)).backedUpTo;
        mkdirSync(stateRoot, { recursive: true });
        writeFileSync(join(stateRoot, 'events.jsonl'), '{"ts":"run-2"}\n', 'utf-8');
        const second = (await backupAndRemoveStateRoot(stateRoot)).backedUpTo;

        assert.notEqual(first, second);
        assert.equal(readFileSync(join(first, 'events.jsonl'), 'utf-8'), '{"ts":"run-1"}\n');
        assert.equal(readFileSync(join(second, 'events.jsonl'), 'utf-8'), '{"ts":"run-2"}\n');
        assert.equal(readFileSync(join(`${stateRoot}.bak`, 'events.jsonl'), 'utf-8'), '{"ts":"OLD-stale"}\n');
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('runShutdown ends the tmux side only: state_root, mail and work files stay, without a grace wait', async () => {
    const { base, stateRoot } = makeStateRoot();
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify({
        team_name: 'demo-team', state_root: stateRoot, session_name: 'my-team-demo-team-zz:0',
        session_mode: 'detached-session', leader_pane: '%0',
        workers: [{ name: 'a', pane_id: '%1' }],
    }), 'utf-8');
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    const savedTmux = process.env.TMUX;
    delete process.env.TMUX; // never treat the test runner's session as the team session
    const origLog = console.log; console.log = () => {};
    try {
        // tmux stubbed: under a loaded full suite each real tmux call took up to seconds (T62), which no
        // bound on shutdown's own time could tell from a grace wait. The old wait was 10 s by default
        // (MY_TEAM_GRACE_MS, removed in 56da3ce); half of it still catches it with room for any load.
        const killed = [];
        const t0 = Date.now();
        await runShutdown({ team: 'demo-team' }, {
            listPanes: async () => [],
            killTeamSession: async (session) => { killed.push(session); },
            killWorkerPanes: async () => { throw new Error('a detached session is killed whole'); },
        });
        const took = Date.now() - t0;
        assert.deepEqual(killed, ['my-team-demo-team-zz:0'], 'the team session is killed right away');
        assert.ok(took < 5000, `shutdown took ${took}ms: a grace wait is back`);
        assert.deepEqual(backups(stateRoot), [], 'nothing moved to .bak');
        assert.equal(readFileSync(join(stateRoot, 'mailbox', 'alice.json'), 'utf-8'), MAIL, 'mail kept');
        assert.equal(readFileSync(join(stateRoot, 'work', 'notes.md'), 'utf-8'), 'half done\n', 'work kept');
        assert.equal(existsSync(join(stateRoot, 'manifest.json')), true, 'manifest kept: status reads the team as stopped');
    } finally {
        console.log = origLog;
        if (savedTmux !== undefined) process.env.TMUX = savedTmux;
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
});

function quiet() {
    const saved = console.log;
    const lines = [];
    console.log = (...a) => { lines.push(a.join(' ')); };
    return { lines, restore: () => { console.log = saved; } };
}

test('a new team (no --continue) moves the previous state_root to .bak and starts empty', async () => {
    const { base, stateRoot } = makeStateRoot();
    const out = quiet();
    try {
        await prepareStateRoot(stateRoot, { keep: false });
        out.restore();
        assert.deepEqual(readdirSync(stateRoot), [], 'starts empty');
        assert.equal(readFileSync(join(backups(stateRoot)[0], 'mailbox', 'alice.json'), 'utf-8'), MAIL, 'previous run kept in .bak');
        assert.ok(out.lines.some((l) => l.includes('.bak')), 'says where the previous state went');
    } finally {
        out.restore();
        rmSync(base, { recursive: true, force: true });
    }
});

const AT = '2026-11-21T00:00:00.000Z';
const row = (extra) => ({ created_at: AT, created_by: 'pm', ...extra });

/** A board.db under `stateRoot` with 2 open + 1 backlog + 1 fixed finding, 2 live + 1 done task, 1 open + 1 answered decision. */
async function seedBoard(stateRoot) {
    const store = createSqliteStore(join(stateRoot, 'board.db'));
    await store.open();
    const finding = (id, state) => ({ kind: 'finding', row: row({ id, verdict_id: 'R1', task_id: 'T1', severity: 'must', summary: 's', repro: 'r', state }) });
    const task = (id, state) => ({ kind: 'task', row: row({ id, title: id, state, priority: 1 }) });
    const brief = { question: 'A or B?' };
    await store.apply({ creates: [
        task('T1', 'doing'), task('T2', 'new'), task('T3', 'done'),
        finding('R1 M1', 'open'), finding('R1 M2', 'open'), finding('R1 L1', 'backlog'), finding('R1 L2', 'fixed'),
        { kind: 'decision', row: row({ id: 'D1', tasks: ['T1'], brief, state: 'open', answer: null }) },
        { kind: 'decision', row: row({ id: 'D2', tasks: ['T1'], brief, state: 'answered', answer: { chosen: 'A', answer: 'a', answered_by: 'user', answered_at: AT } }) },
    ] });
    await store.close();
}

test('unfinishedBoardSummary counts what is still open, and is null without a board.db', needsSqlite, async () => {
    const { base, stateRoot } = makeStateRoot();
    try {
        assert.equal(await unfinishedBoardSummary(stateRoot), null);
        await seedBoard(stateRoot);
        assert.equal(await unfinishedBoardSummary(stateRoot),
            'board.db: open finding 2, backlog finding 1, unfinished task 2, open decision 1');
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('a new team prints the unfinished board state and the .bak path to stderr before moving, and the board comes along unchanged', needsSqlite, async () => {
    const { base, stateRoot } = makeStateRoot();
    await seedBoard(stateRoot);
    const out = quiet();
    const errs = [];
    const savedErr = console.error;
    console.error = (...a) => { errs.push(a.join(' ')); };
    try {
        await prepareStateRoot(stateRoot, { keep: false });
        out.restore();
        console.error = savedErr;
        const [bak] = backups(stateRoot);
        assert.equal(errs.length, 1);
        assert.ok(errs[0].includes('open finding 2, backlog finding 1, unfinished task 2, open decision 1'), errs[0]);
        assert.ok(errs[0].includes(bak), 'names the path it moves to');
        assert.equal(existsSync(join(bak, 'board.db')), true);
        assert.deepEqual(readdirSync(bak).filter((n) => n.startsWith('board.db') && n !== 'board.db'), [], 'a read-only look leaves no -wal, -shm or migration copy');
    } finally {
        console.error = savedErr;
        out.restore();
        rmSync(base, { recursive: true, force: true });
    }
});

test('a new team without a board.db prints no summary', async () => {
    const { base, stateRoot } = makeStateRoot();
    const out = quiet();
    const errs = [];
    const savedErr = console.error;
    console.error = (...a) => { errs.push(a.join(' ')); };
    try {
        await prepareStateRoot(stateRoot, { keep: false });
        assert.deepEqual(errs, []);
    } finally {
        console.error = savedErr;
        out.restore();
        rmSync(base, { recursive: true, force: true });
    }
});

test('--continue keeps mail (undelivered too), work files and events as they are', async () => {
    const { base, stateRoot } = makeStateRoot();
    try {
        await prepareStateRoot(stateRoot, { keep: true });
        assert.equal(readFileSync(join(stateRoot, 'mailbox', 'alice.json'), 'utf-8'), MAIL);
        assert.equal(readFileSync(join(stateRoot, 'work', 'notes.md'), 'utf-8'), 'half done\n');
        assert.equal(readFileSync(join(stateRoot, 'events.jsonl'), 'utf-8'), '{"ts":"run-1"}\n');
        assert.deepEqual(backups(stateRoot), []);
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});

test('--continue with no previous state starts a new team and says so in one line', async () => {
    const base = mkdtempSync(join(tmpdir(), 'my-team-continue-'));
    const stateRoot = join(base, 'fresh-team');
    const out = quiet();
    try {
        await prepareStateRoot(stateRoot, { keep: true });
        out.restore();
        assert.deepEqual(readdirSync(stateRoot), []);
        assert.equal(out.lines.length, 1);
        assert.match(out.lines[0], /--continue/);
    } finally {
        out.restore();
        rmSync(base, { recursive: true, force: true });
    }
});

test('a new team refuses to start when the previous state cannot be moved aside', async (t) => {
    if (typeof process.getuid === 'function' && process.getuid() === 0) {
        t.skip('cannot test EACCES as root');
        return;
    }
    const { base, stateRoot } = makeStateRoot();
    try {
        chmodSync(base, 0o500);
        await assert.rejects(prepareStateRoot(stateRoot, { keep: false }), /--continue/);
        assert.equal(readFileSync(join(stateRoot, 'mailbox', 'alice.json'), 'utf-8'), MAIL, 'nothing lost');
    } finally {
        chmodSync(base, 0o700);
        rmSync(base, { recursive: true, force: true });
    }
});

function splitTeam() {
    const { base, stateRoot } = makeStateRoot();
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify({
        team_name: 'demo-team', state_root: stateRoot, session_name: 'host:0', session_mode: 'split-pane',
        leader_pane: '%0', workers: [{ name: 'pm', pane_id: '%1' }, { name: 'dev', pane_id: '%2' }],
    }), 'utf-8');
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot };
}

function killSpy(panes) {
    const killed = [];
    return {
        killed,
        deps: {
            listPanes: async () => panes,
            killWorkerPanes: async ({ paneIds }) => { killed.push(...paneIds); },
            killTeamSession: async (name) => { killed.push(name); },
        },
    };
}

test('shutdown of a stopped split-pane team kills nothing: its pane ids may be other panes now (R1)', async () => {
    const { base } = splitTeam();
    const { killed, deps } = killSpy([{ session: 'my-team-other-zz', paneId: '%1', worker: 'x1' }, { session: 'host', paneId: '%0', worker: '' }]);
    const out = quiet();
    try {
        await runShutdown({ team: 'demo-team' }, deps);
        out.restore();
        assert.deepEqual(killed, []);
    } finally {
        out.restore();
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
});

test('shutdown of a running split-pane team kills its live worker panes only', async () => {
    const { base } = splitTeam();
    const { killed, deps } = killSpy([{ session: 'host', paneId: '%0', worker: '' }, { session: 'host', paneId: '%1', worker: 'pm' }]);
    const out = quiet();
    try {
        await runShutdown({ team: 'demo-team' }, deps);
        out.restore();
        assert.deepEqual(killed, ['%1']);
    } finally {
        out.restore();
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
});

test('a new start is refused while the team of the same state_root runs, and its state stays (M3)', async () => {
    const { base, stateRoot } = splitTeam();
    const config = join(base, 'demo.json');
    writeFileSync(config, JSON.stringify({ team_name: 'demo-team', state_root: stateRoot,
        workers: [{ name: 'pm', agent_type: 'claude', cwd: tmpdir() }] }));
    const live = [{ session: 'host', paneId: '%0', worker: '' }, { session: 'host', paneId: '%2', worker: 'dev' }];
    const out = quiet();
    try {
        await assert.rejects(runStart({ config }, { listPanes: async () => live }), /already running/);
        assert.equal(readFileSync(join(stateRoot, 'mailbox', 'alice.json'), 'utf-8'), MAIL);
        assert.deepEqual(backups(stateRoot), []);
        // stopped: only the host pane is left, so a dry run goes through
        const plan = await runStart({ config, dryRun: true }, { listPanes: async () => [live[0]] });
        assert.equal(plan.dryRun, true);
    } finally {
        out.restore();
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
});

test('a new start is refused when tmux cannot say whether the team runs, and its state stays (R2)', async () => {
    const { base, stateRoot } = splitTeam();
    const config = join(base, 'demo.json');
    writeFileSync(config, JSON.stringify({ team_name: 'demo-team', state_root: stateRoot,
        workers: [{ name: 'pm', agent_type: 'claude', cwd: tmpdir() }] }));
    try {
        await assert.rejects(runStart({ config }, { listPanes: async () => { throw new Error('lost server'); } }), /lost server/);
        assert.equal(readFileSync(join(stateRoot, 'mailbox', 'alice.json'), 'utf-8'), MAIL);
        assert.deepEqual(backups(stateRoot), []);
    } finally {
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    }
});
