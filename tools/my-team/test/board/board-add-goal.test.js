/**
 * board-add of a task with no parent names its goal or says it is a single task (T221, D#23), through the real
 * CLI. The state base is <tmp>/sessions, so goal files live in <tmp>/docs/<team>/goals, never the user's.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));
const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const needsSqlite = hasSqlite ? {} : { skip: 'node:sqlite needs Node >= 22.13' };

function team(t, roles = ['orchestrator', 'worker']) {
    const top = mkdtempSync(join(tmpdir(), 'mt-add-goal-'));
    t.after(() => rmSync(top, { recursive: true, force: true }));
    const base = join(top, 'sessions');
    const root = join(base, 'demo');
    mkdirSync(root, { recursive: true });
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: 'demo', state_root: root, session_name: 'none:0', board: { store: 'sqlite' },
        workers: ['pm', 'core'].map((name, i) => ({ name, role: roles[i], agent_type: 'claude', pane_id: `%${990 + i}` })),
    }));
    const goals = join(top, 'docs', 'demo', 'goals');
    const goal = (file, text) => { mkdirSync(goals, { recursive: true }); writeFileSync(join(goals, file), text); };
    const add = (worker, input) => {
        const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base, MY_TEAM_WORKER: `demo/${worker}` };
        for (const k of ['OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
        const r = spawnSync(process.execPath, [MY_TEAM, 'api', 'board-add', '--input', JSON.stringify({ team_name: 'demo', ...input }), '--json'],
            { env, encoding: 'utf-8' });
        return { code: r.status, out: r.stdout + r.stderr };
    };
    return { goals, goal, add };
}

const ORDER = '# G3 대시보드\n\n## 순서\n- T178 -> T179, T180\n- T179:1 -> T181:2-3\n';

function refused(r, ...parts) {
    assert.notEqual(r.code, 0, r.out);
    assert.match(r.out, /invalid/);
    for (const p of parts) assert.ok(r.out.includes(p), `"${p}" in: ${r.out}`);
}

test('a task with no parent and neither goal nor single is refused with the goals folder and how to fix it', needsSqlite, (t) => {
    const { goals, add } = team(t);
    refused(add('pm', { id: 'T1', title: 't' }), 'neither goal nor single', goals, '## 순서', '- <before> -> <after>', '"goal":"G<n>"', '"single":true');
});

test('goal and single together are refused, and single must be true', needsSqlite, (t) => {
    const { goal, add } = team(t);
    goal('G3-dash.md', ORDER);
    refused(add('pm', { id: 'T178', title: 't', goal: 'G3', single: true }), 'goal and single both given');
    refused(add('pm', { id: 'T1', title: 't', single: false }), 'single must be true');
});

test('a goal with no file, a task its order does not name, or a G number of two files is refused', needsSqlite, (t) => {
    const { goals, goal, add } = team(t);
    refused(add('pm', { id: 'T178', title: 't', goal: 'G3' }), `no goal file G3-<slug>.md in ${goals}`);
    goal('G3-dash.md', ORDER);
    refused(add('pm', { id: 'T999', title: 't', goal: 'G3' }), `T999 is not in the ## 순서 section of ${join(goals, 'G3-dash.md')}`);
    refused(add('pm', { title: 't', goal: 'G3' }), "goal needs the task's id");
    goal('G4-plain.md', '# G4\n\n## 요청\nno order\n');
    refused(add('pm', { id: 'T1', title: 't', goal: 'G4' }), 'which has none');
    goal('G3-other.md', ORDER);
    refused(add('pm', { id: 'T178', title: 't', goal: 'G3' }), 'G3 names 2 files', 'G3-dash.md, G3-other.md');
});

test('a task its goal orders, as a whole or by items, and a single task are added', needsSqlite, (t) => {
    const { goal, add } = team(t);
    goal('G3-dash.md', ORDER);
    goal('G30-later.md', '# G30\n\n## 순서\n- T500 -> T501\n');
    for (const id of ['T178', 'T179', 'T181']) {
        const r = add('pm', { id, title: id, goal: 'G3' });
        assert.equal(r.code, 0, r.out);
    }
    refused(add('pm', { id: 'T500', title: 't', goal: 'G3' }), 'T500 is not in');
    const r = add('pm', { id: 'T2', title: 'one-off', single: true });
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /"id": ?"T2"/);
});

test('T222: a task on a list line of its goal is added, mixed with order lines or alone', needsSqlite, (t) => {
    const { goal, add } = team(t);
    goal('G5-mixed.md', '# G5\n\n## 순서\n- T1 -> T2\n- T3, T4\n');
    goal('G6-list.md', '# G6\n\n## 순서\n- T7, T8\n');
    for (const [id, g] of [['T3', 'G5'], ['T4', 'G5'], ['T1', 'G5'], ['T7', 'G6']]) {
        const r = add('pm', { id, title: id, goal: g });
        assert.equal(r.code, 0, r.out);
    }
    refused(add('pm', { id: 'T9', title: 't', goal: 'G6' }), 'T9 is not in', '"- T1, T2"');
});

test('a derived task needs neither; a worker who is not pm is refused as before', needsSqlite, (t) => {
    const { add } = team(t);
    assert.equal(add('pm', { id: 'T1', title: 't', single: true }).code, 0);
    const derived = add('pm', { parent: 'T1', title: 'fix' });
    assert.equal(derived.code, 0, derived.out);
    const r = add('core', { id: 'T5', title: 't' });
    assert.notEqual(r.code, 0);
    assert.match(r.out, /forbidden/);
    assert.match(r.out, /core is not the team's pm/);
});

test('in a team that declares no roles every worker is pm, so each names a goal or single', needsSqlite, (t) => {
    const { add } = team(t, [undefined, undefined]);
    refused(add('core', { id: 'T1', title: 't' }), 'neither goal nor single');
    assert.equal(add('core', { id: 'T1', title: 't', single: true }).code, 0);
});
