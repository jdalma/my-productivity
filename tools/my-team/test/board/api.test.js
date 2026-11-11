/**
 * The board's read commands through the real CLI (T63d; docs/board.md, Turning it on and Commands): a team is a board team
 * when its config (and so its manifest) has a `board` item; the board file is <state_root>/board.db; who asks
 * comes from MY_TEAM_WORKER like send-message (T58); with --json an error is also a JSON line on stdout.
 * Every team lives under a temporary state base, never the user's.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { createBoard } from '../../src/board/core/service.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));
const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const needsSqlite = hasSqlite ? {} : { skip: 'node:sqlite needs Node >= 22.13' };
const ROSTER = [{ name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' }, { name: 'rv', role: 'worker' }];

function team(t, name, { board = { store: 'sqlite' } } = {}) {
    const base = mkdtempSync(join(tmpdir(), 'mt-board-api-'));
    t.after(() => rmSync(base, { recursive: true, force: true }));
    const root = join(base, name);
    mkdirSync(root, { recursive: true });
    const manifest = {
        team_name: name, state_root: root, session_name: `my-team-${name}-x:0`,
        workers: ROSTER.map((w) => ({ name: w.name, role: w.role, agent_type: 'claude', pane_id: '%999' })),
        ...(board ? { board } : {}),
    };
    writeFileSync(join(root, 'manifest.json'), JSON.stringify(manifest));
    return { base, root };
}

function cli(base, args, { worker } = {}) {
    const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base };
    for (const k of ['MY_TEAM_WORKER', 'OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
    if (worker) env.MY_TEAM_WORKER = worker;
    const r = spawnSync(process.execPath, [MY_TEAM, 'api', ...args], { env, encoding: 'utf-8' });
    let json = null;
    try { json = JSON.parse(r.stdout); } catch { /* not JSON */ }
    return { code: r.status, out: r.stdout, err: r.stderr, json };
}

async function fill(root) {
    const store = createSqliteStore(join(root, 'board.db'));
    await store.open();
    let tick = 0;
    const now = () => new Date(Date.UTC(2026, 10, 11, 0, 0, tick++)).toISOString();
    const git = { range: async (repo, base, commit) => ({ ancestor: true, commits: [commit] }) };
    const as = (actor) => createBoard({ store, roster: () => ROSTER, actor, now, git });
    await as('pm').add({ id: 'T1', title: 'one', assignee: 'core', reviewer: 'rv', ticket: '/t.md', constraints: 'c', base: '0'.repeat(40) });
    await as('core').take({ id: 'T1' });
    await as('core').land({ id: 'T1', repo: '/repo', commit: '1'.repeat(40), check: { cmd: 'npm test', result: 'ok' }, focus: ['f'], closes: [], report: '/r.md', review_report: '/R.md' });
    await as('pm').add({ id: 'T2', title: 'two', assignee: 'core', reviewer: 'rv', ticket: '/t.md', constraints: 'c' });
    await store.close();
}

test('board-status, board-inbox and board-review-queue read a board team\'s board.db', needsSqlite, async (t) => {
    const { base, root } = team(t, 'bt');
    await fill(root);
    const s = cli(base, ['board-status', '--input', '{"team_name":"bt"}', '--json']);
    assert.equal(s.code, 0, s.err);
    assert.deepEqual(s.json.tasks.map((x) => [x.id, x.state]), [['T1', 'review'], ['T2', 'ready']]);
    assert.equal(s.json.store.adapter, 'sqlite');
    assert.doesNotMatch(s.err, /ExperimentalWarning/);

    const fam = cli(base, ['board-status', '--input', '{"team_name":"bt","task":"T1"}', '--json']);
    assert.deepEqual(fam.json.landings.map((l) => l.id), ['T1#1']);

    const i = cli(base, ['board-inbox', '--input', '{"team_name":"bt"}', '--json'], { worker: 'bt/core' });
    assert.equal(i.code, 0, i.err);
    assert.deepEqual(i.json.tasks.map((x) => x.id), ['T2']);
    assert.ok(i.json.cursor);

    const q = cli(base, ['board-review-queue', '--input', '{"team_name":"bt"}', '--json'], { worker: 'bt/rv' });
    assert.deepEqual(q.json.queue.map((r) => r.landing.id), ['T1#1']);
    const byName = cli(base, ['board-review-queue', '--input', '{"team_name":"bt","worker":"rv"}', '--json']);
    assert.deepEqual(byName.json.queue.map((r) => r.landing.id), ['T1#1'], 'from the user\'s shell, the worker named in the input');
});

test('a team without a board item: board-unavailable, as JSON on stdout and a line on stderr, and no board.db', (t) => {
    const { base, root } = team(t, 'plain', { board: null });
    for (const cmd of ['board-status', 'board-inbox', 'board-review-queue']) {
        const r = cli(base, [cmd, '--input', '{"team_name":"plain","worker":"core"}', '--json']);
        assert.equal(r.code, 1, cmd);
        assert.deepEqual([r.json.ok, r.json.code], [false, 'board-unavailable'], cmd);
        assert.match(r.json.message, /no board/);
        assert.match(r.err, /^\[my-team\] error: board-unavailable: /m);
    }
    assert.equal(existsSync(join(root, 'board.db')), false);
    const plain = cli(base, ['board-status', '--input', '{"team_name":"plain"}']);
    assert.equal(plain.code, 1);
    assert.equal(plain.out, '', 'without --json, stdout stays empty');
});

test('who asks: MY_TEAM_WORKER of another team is refused; without it the input must name the worker', needsSqlite, async (t) => {
    const { base, root } = team(t, 'bt');
    await fill(root);
    const other = cli(base, ['board-inbox', '--input', '{"team_name":"bt"}', '--json'], { worker: 'elsewhere/core' });
    assert.deepEqual([other.code, other.json.code], [1, 'forbidden']);
    const posing = cli(base, ['board-inbox', '--input', '{"team_name":"bt","worker":"rv"}', '--json'], { worker: 'bt/core' });
    assert.deepEqual([posing.code, posing.json.code], [1, 'forbidden']);
    const nobody = cli(base, ['board-inbox', '--input', '{"team_name":"bt"}', '--json']);
    assert.deepEqual([nobody.code, nobody.json.code], [1, 'invalid']);
    const stranger = cli(base, ['board-inbox', '--input', '{"team_name":"bt","worker":"ghost"}', '--json']);
    assert.deepEqual([stranger.code, stranger.json.code], [1, 'invalid']);
    const outsider = cli(base, ['board-status', '--input', '{"team_name":"bt"}', '--json'], { worker: 'elsewhere/pm' });
    assert.deepEqual([outsider.code, outsider.json.code], [1, 'forbidden'], 'R69 L1: another team\'s worker does not read this board');
    assert.equal(cli(base, ['board-status', '--input', '{"team_name":"bt"}', '--json']).code, 0, 'the user\'s shell may');
    const missing = cli(base, ['board-status', '--input', '{"team_name":"nope"}', '--json']);
    assert.deepEqual([missing.code, missing.json.code], [1, 'not-found']);
});
