/**
 * `my-team api goal-order` [pure] — the order of each goal's tasks (T212). The contract is docs/board.md, Goal order.
 *
 * Goal files are ~/.my-team/docs/<team>/goals/G<n>-<slug>.md (the docs folder sits next to the sessions folder,
 * so MY_TEAM_STATE_ROOT_BASE moves it too). Their `## 순서` section is sorted into waves (board/core/goal-order.js)
 * and matched against the board read like board-status. Nothing is written.
 *
 * Input:  { team_name, goal?, template? } goal "G3" for one goal; left out, every goal. template true: { ok, template }
 *                                         only, a new goal file to fill in (T52); no goal file or board is read
 * Output: { ok, goals: [ { id, title, path,
 *             waves: [ [ { ref, task, items: [n]|null, after: [ { ref, task, items } ], title, state, status,
 *                          blocked_by: [ { ref, state } ] } ] ],
 *             ready_now: [ref], unregistered: [task id], cycle: [ref…]|null, errors: [ { line, text, reason, formats? } ] } ] }
 * status: done | ready_now | waiting | cancelled | unregistered. ready_now: every predecessor complete and the unit
 * not done or cancelled, so a task already under way is in it too, whatever its state (doing, review, waiting…).
 * A goal without `## 순서`: waves []. A cycle: cycle set, waves []. Syntax errors: errors set, waves [] (a partial
 * order would put a task in ready_now whose predecessor line was mistyped); each names the forms a line takes in formats. One G number in two or more files:
 * one entry, path the first file by name, title null, waves [], an error per file (T230). Only regular files
 * count: a directory named G<n>-x.md is skipped. A team without a board: every node unregistered.
 */

import { existsSync, readdirSync, readFileSync, statSync } from 'fs';
import { dirname, join } from 'path';

import { refuseOutsider, withBoard } from '../../board/compose.js';
import { annotate, GOAL_TEMPLATE, parseOrder, waves } from '../../board/core/goal-order.js';
import { status } from '../../board/core/queries.js';
import { BoardError } from '../../board/core/rules.js';
import { getStateRootBase } from '../../lib/state-root.js';

export const GOAL_FILE = /^(G\d+)-.*\.md$/;

/** The team's goals folder: docs/<team>/goals next to the state base. */
export const goalsDir = (team) => join(dirname(getStateRootBase()), 'docs', team, 'goals');

/** The goal files in `dir` as { id, path }, by number then name. Only regular files (or links to one) count (R7 L2). */
export function goalFiles(dir) {
    if (!existsSync(dir)) return [];
    return readdirSync(dir)
        .filter((f) => GOAL_FILE.test(f) && statSync(join(dir, f), { throwIfNoEntry: false })?.isFile())
        .map((f) => ({ id: GOAL_FILE.exec(f)[1], path: join(dir, f) }))
        .sort((a, b) => Number(a.id.slice(1)) - Number(b.id.slice(1)) || (a.path < b.path ? -1 : 1));
}

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
    const sorted = waves(order.edges, order.listed);
    if (sorted.cycle) return { id, title, path, ...empty, cycle: sorted.cycle, errors };
    return { id, title, path, ...annotate(sorted.waves, tasks), cycle: null, errors };
}

/** One id in several files (R7 L1): which one is meant is the user's to say, so no order is read from any. */
function duplicate(id, paths) {
    const reason = `${id} names ${paths.length} files; give each goal its own number`;
    return { id, title: null, path: paths[0], waves: [], ready_now: [], unregistered: [], cycle: null,
        errors: paths.map((p) => ({ line: null, text: p, reason })) };
}

export async function runApiGoalOrder(input = {}, env = process.env) {
    refuseOutsider(env, input.team_name);
    if (input.template) return { ok: true, template: GOAL_TEMPLATE };
    const tasks = await boardTasks(input.team_name);
    const dir = goalsDir(input.team_name);
    const byId = new Map();
    for (const g of goalFiles(dir)) byId.set(g.id, [...(byId.get(g.id) ?? []), g.path]);
    const wanted = input.goal ? [...byId].filter(([id]) => id === input.goal) : [...byId];
    if (input.goal && !wanted.length) throw new BoardError('not-found', `no goal ${input.goal} in ${dir}`);
    return { ok: true, goals: wanted.map(([id, paths]) => paths.length > 1 ? duplicate(id, paths) : goalOf(paths[0], id, tasks)) };
}
