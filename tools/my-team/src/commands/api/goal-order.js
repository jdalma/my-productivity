/**
 * `my-team api goal-order` [pure] — the order of each goal's tasks (T212; plan research/my-team-goal-order-plan.md 2.4).
 *
 * Goal files are ~/.my-team/docs/<team>/goals/G<n>-<slug>.md (the docs folder sits next to the sessions folder,
 * so MY_TEAM_STATE_ROOT_BASE moves it too). Their `## 순서` section is sorted into waves (board/core/goal-order.js)
 * and matched against the board read like board-status. Nothing is written.
 *
 * Input:  { team_name, goal? }           goal "G3" for one goal; left out, every goal
 * Output: { ok, goals: [ { id, title, path,
 *             waves: [ [ { ref, task, items: [n]|null, after: [ { ref, task, items } ], title, state, status,
 *                          blocked_by: [ { ref, state } ] } ] ],
 *             ready_now: [ref], unregistered: [task id], cycle: [ref…]|null, errors: [ { line, text, reason } ] } ] }
 * status: done | ready_now | waiting | cancelled | unregistered. ready_now: every predecessor complete and not done
 * yet, so a task already under way is in it too (its state says doing).
 * A goal without `## 순서`: waves []. A cycle: cycle set, waves []. Syntax errors: errors set, waves [] (a partial
 * order would put a task in ready_now whose predecessor line was mistyped). A team without a board: every node
 * unregistered.
 */

import { existsSync, readdirSync, readFileSync } from 'fs';
import { dirname, join } from 'path';

import { refuseOutsider, withBoard } from '../../board/compose.js';
import { annotate, parseOrder, waves } from '../../board/core/goal-order.js';
import { status } from '../../board/core/queries.js';
import { BoardError } from '../../board/core/rules.js';
import { getStateRootBase } from '../../lib/state-root.js';

export const GOAL_FILE = /^(G\d+)-.*\.md$/;

/** The team's goals folder: docs/<team>/goals next to the state base. */
export const goalsDir = (team) => join(dirname(getStateRootBase()), 'docs', team, 'goals');

async function boardTasks(team) {
    try {
        return await withBoard(team, async ({ store, roster }) => (await status(store, roster)).tasks);
    } catch (err) {
        if (err.code === 'board-unavailable') return [];
        throw err;
    }
}

function goalOf(path, id, tasks) {
    const text = readFileSync(path, 'utf-8');
    const heading = /^# +(.*)$/m.exec(text)?.[1].trim() ?? '';
    const title = heading.startsWith(`${id} `) ? heading.slice(id.length + 1).trim() : heading || null;
    const empty = { waves: [], ready_now: [], unregistered: [], cycle: null };
    const order = parseOrder(text);
    const errors = order.invalid;
    if (!order.found || errors.length) return { id, title, path, ...empty, errors };
    const sorted = waves(order.edges);
    if (sorted.cycle) return { id, title, path, ...empty, cycle: sorted.cycle, errors };
    return { id, title, path, ...annotate(sorted.waves, tasks), cycle: null, errors };
}

export async function runApiGoalOrder(input = {}, env = process.env) {
    refuseOutsider(env, input.team_name);
    const tasks = await boardTasks(input.team_name);
    const dir = goalsDir(input.team_name);
    const files = existsSync(dir) ? readdirSync(dir).filter((f) => GOAL_FILE.test(f)) : [];
    const found = files
        .map((f) => ({ id: GOAL_FILE.exec(f)[1], path: join(dir, f) }))
        .sort((a, b) => Number(a.id.slice(1)) - Number(b.id.slice(1)) || (a.path < b.path ? -1 : 1));
    const wanted = input.goal ? found.filter((g) => g.id === input.goal) : found;
    if (input.goal && !wanted.length) throw new BoardError('not-found', `no goal ${input.goal} in ${dir}`);
    return { ok: true, goals: wanted.map((g) => goalOf(g.path, g.id, tasks)) };
}
