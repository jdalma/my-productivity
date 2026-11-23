/**
 * `my-team api goal-order` through the real CLI (T212; docs/board.md, Goal order).
 * The state base is <tmp>/sessions, so goal files live in <tmp>/docs/<team>/goals, never the user's.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'child_process';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { createBoard } from '../../src/board/core/service.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));
const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const needsSqlite = hasSqlite ? {} : { skip: 'node:sqlite needs Node >= 22.13' };
const ROSTER = [{ name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' }];

function team(t, name, { board = { store: 'sqlite' } } = {}) {
    const top = mkdtempSync(join(tmpdir(), 'mt-goal-order-'));
    t.after(() => rmSync(top, { recursive: true, force: true }));
    const base = join(top, 'sessions');
    const root = join(base, name);
    mkdirSync(root, { recursive: true });
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: name, state_root: root, session_name: `my-team-${name}-x:0`,
        workers: ROSTER.map((w) => ({ name: w.name, role: w.role, agent_type: 'claude', pane_id: '%999' })),
        ...(board ? { board } : {}),
    }));
    const goals = join(top, 'docs', name, 'goals');
    const goal = (file, text) => { mkdirSync(goals, { recursive: true }); writeFileSync(join(goals, file), text); };
    return { base, root, goal, goals };
}

function goalOrder(base, input) {
    const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base };
    for (const k of ['MY_TEAM_WORKER', 'OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
    const r = spawnSync(process.execPath, [MY_TEAM, 'api', 'goal-order', '--input', JSON.stringify(input), '--json'], { env, encoding: 'utf-8' });
    return { code: r.status, err: r.stderr, json: JSON.parse(r.stdout) };
}

const DASHBOARD = `# G3 대시보드: 사용량·인사이트

## 요청
"거시적인 의미의 대시보드"

## 순서
- T178 -> T179, T180
- T179, T180 -> T181, T177
- T181:1 -> T177:4-7
- T177, T181 -> T192
`;

async function dashboardBoard(root) {
    const store = createSqliteStore(join(root, 'board.db'));
    await store.open();
    let tick = 0;
    const now = () => new Date(Date.UTC(2026, 10, 19, 0, 0, tick++)).toISOString();
    const as = (actor) => createBoard({ store, roster: () => ROSTER, actor, now, git: null });
    for (const id of ['T181', 'T177']) await as('pm').add({ id, title: `title ${id}`, assignee: 'core' });
    await as('core').take({ id: 'T181' });
    await as('core').progress({ id: 'T181', item: 1, note: 'types committed', done: true });
    await store.close();
}

test('a team without goal files has no goals', () => {
    const { base } = team({ after() {} }, 'g0');
    const r = goalOrder(base, { team_name: 'g0' });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(r.json, { ok: true, goals: [] });
});

test('goals come in number order; one without the order section has no waves; goal picks one', needsSqlite, async (t) => {
    const { base, root, goal, goals } = team(t, 'g1');
    await dashboardBoard(root);
    goal('G10-later.md', '# G10 later\n\n## 순서\n- A -> B\n');
    goal('G3-dashboard.md', DASHBOARD);
    goal('G2-plain.md', '# G2 no order yet\n\n## 요청\nsomething\n');
    goal('notes.md', '# not a goal\n');

    const all = goalOrder(base, { team_name: 'g1' });
    assert.equal(all.code, 0, all.err);
    assert.deepEqual(all.json.goals.map((g) => [g.id, g.title]), [['G2', 'no order yet'], ['G3', '대시보드: 사용량·인사이트'], ['G10', 'later']]);
    const [plain, dash] = all.json.goals;
    assert.deepEqual(plain, { id: 'G2', title: 'no order yet', path: join(goals, 'G2-plain.md'), waves: [], ready_now: [], unregistered: [], cycle: null, errors: [] });

    // the dashboard against the board: T181 reported item 1, the others are not on the board
    assert.deepEqual(dash.waves.map((w) => w.map((n) => n.ref)), [['T178'], ['T179', 'T180'], ['T181', 'T177'], ['T177:4-7'], ['T192']]);
    assert.deepEqual(dash.unregistered, ['T178', 'T179', 'T180', 'T192']);
    const range = dash.waves[3][0];
    assert.deepEqual({ task: range.task, items: range.items, title: range.title, state: range.state, status: range.status },
        { task: 'T177', items: [4, 5, 6, 7], title: 'title T177', state: 'ready', status: 'waiting' });
    // T181 item 1 is done; what still blocks the range is the unregistered T179 and T180 its body waits on
    assert.deepEqual(range.blocked_by, [{ ref: 'T179', state: 'unregistered' }, { ref: 'T180', state: 'unregistered' }]);

    const one = goalOrder(base, { team_name: 'g1', goal: 'G10' });
    assert.deepEqual(one.json.goals.map((g) => g.id), ['G10']);
    const none = goalOrder(base, { team_name: 'g1', goal: 'G4' });
    assert.equal(none.code, 1);
    assert.equal(none.json.code, 'not-found');
});

test('a cycle gives its path and no waves; syntax errors give their lines and no waves', needsSqlite, async (t) => {
    const { base, goal } = team(t, 'g2');
    goal('G1-loop.md', '# G1 loop\n## 순서\n- A -> B\n- B -> A\n');
    goal('G2-typo.md', '# G2 typo\n## 순서\n- A -> B\n- A => C\n');
    const [loop, typo] = goalOrder(base, { team_name: 'g2' }).json.goals;
    assert.deepEqual([loop.cycle, loop.waves, loop.ready_now], [['A', 'B', 'A'], [], []]);
    assert.deepEqual([typo.cycle, typo.waves, typo.errors.map((e) => e.line)], [null, [], [4]]);
});

test('R7 L1: one G number in two files is one goal with an error per file, and no order', (t) => {
    const { base, goal, goals } = team(t, 'g6', { board: null });
    goal('G5-b.md', '# G5 b\n## 순서\n- A -> B\n');
    goal('G5-a.md', '# G5 a\n## 순서\n- C -> D\n');
    goal('G6-other.md', '# G6 other\n## 순서\n- E\n');
    const r = goalOrder(base, { team_name: 'g6' });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(r.json.goals.map((g) => g.id), ['G5', 'G6']);
    const reason = 'G5 names 2 files; give each goal its own number';
    assert.deepEqual(r.json.goals[0], {
        id: 'G5', title: null, path: join(goals, 'G5-a.md'), waves: [], ready_now: [], unregistered: [], cycle: null,
        errors: [{ line: null, text: join(goals, 'G5-a.md'), reason }, { line: null, text: join(goals, 'G5-b.md'), reason }],
    });
    assert.deepEqual(goalOrder(base, { team_name: 'g6', goal: 'G5' }).json.goals.map((g) => g.errors.length), [2]);
});

test('R7 L2: a directory named like a goal file is skipped; a link to a goal file is read', (t) => {
    const { base, goal, goals } = team(t, 'g7', { board: null });
    goal('G1-real.md', '# G1 real\n## 순서\n- A\n');
    mkdirSync(join(goals, 'G2-dir.md'));
    mkdirSync(join(goals, 'G1-dir.md'));
    symlinkSync(join(goals, 'G1-real.md'), join(goals, 'G3-link.md'));
    const r = goalOrder(base, { team_name: 'g7' });
    assert.equal(r.code, 0, r.err);
    assert.deepEqual(r.json.goals.map((g) => [g.id, g.errors.length]), [['G1', 0], ['G3', 0]]);
    assert.equal(goalOrder(base, { team_name: 'g7', goal: 'G2' }).json.code, 'not-found');
});

test('T222: a goal of listed tasks in no order is one wave, all ready_now', needsSqlite, async (t) => {
    const { base, root, goal } = team(t, 'g5');
    await dashboardBoard(root);
    goal('G7-parallel.md', '# G7 parallel\n## 순서\n- T181, T177\n');
    const r = goalOrder(base, { team_name: 'g5' });
    assert.equal(r.code, 0, r.err);
    const [g] = r.json.goals;
    assert.deepEqual([g.waves.map((w) => w.map((n) => n.ref)), g.ready_now, g.errors], [[['T181', 'T177']], ['T181', 'T177'], []]);
});

test('a team without a board gets every node unregistered', (t) => {
    const { base, goal } = team(t, 'g3', { board: null });
    goal('G1-x.md', '# G1 x\n## 순서\n- A -> B\n');
    const r = goalOrder(base, { team_name: 'g3' });
    assert.equal(r.code, 0, r.err);
    const [g] = r.json.goals;
    assert.deepEqual(g.waves.flat().map((n) => [n.ref, n.status]), [['A', 'unregistered'], ['B', 'unregistered']]);
    assert.deepEqual(g.unregistered, ['A', 'B']);
});

test('the board file is opened read-only: goal-order writes nothing to it', needsSqlite, async (t) => {
    const { base, root, goal } = team(t, 'g4');
    await dashboardBoard(root);
    goal('G3-dashboard.md', DASHBOARD);
    const { statSync } = await import('fs');
    const before = statSync(join(root, 'board.db')).mtimeMs;
    assert.equal(goalOrder(base, { team_name: 'g4' }).code, 0);
    assert.equal(statSync(join(root, 'board.db')).mtimeMs, before);
});
