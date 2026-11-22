/**
 * `my-team api board-<command>` for the board's write commands (T63e; docs/board.md, Commands): add, assign,
 * take, note, land, verdict, finding, cancel, announce, wait, answer, ask, decision-edit, progress, edit. The worker acting is the one MY_TEAM_WORKER names
 * (`by` in the input from the user's shell). land's repository is the top level of the acting worker's cwd,
 * not an input; a document task's land has none.
 */

import { existsSync, readdirSync, readFileSync } from 'fs';
import { join } from 'path';

import { actorOf, boardFor, withBoard } from '../../board/compose.js';
import { parseOrder } from '../../board/core/goal-order.js';
import { BoardError, isDocument, pmsOf } from '../../board/core/rules.js';
import { toplevel } from '../../board/git.js';
import { GOAL_FILE, goalsDir } from './goal-order.js';

const fail = (message) => { throw new BoardError('invalid', message); };

/**
 * A task with no parent says which request it serves (T221, D#23): `goal` "G<n>" with its `id` listed in that
 * goal file's `## 순서`, or `single` true for a request that is this one task. Checked only, never stored. The
 * message says how to fix it, for a pm whose AGENTS.md predates the rule.
 */
function requireGoal(team, { id, goal, single }) {
    const dir = goalsDir(team);
    const how = `A task with no parent needs exactly one of: "goal":"G<n>" with its "id", the id listed in the ## 순서 section `
        + `of ${dir}/G<n>-<slug>.md (lines "- <before> -> <after>", each side a comma list of T… or T…:<items>, or "- T1, T2" for tasks in no order); `
        + `or "single":true for a request that is this one task. Write the goal file and its order first, then add the tasks.`;
    if (single !== undefined && single !== true) fail(`single must be true. ${how}`);
    if ((goal === undefined) === (single === undefined)) fail(`${goal === undefined ? 'neither goal nor single given' : 'goal and single both given'}. ${how}`);
    if (single) return;
    if (typeof goal !== 'string' || !/^G\d+$/.test(goal)) fail(`goal must be G<n>, got ${JSON.stringify(goal)}. ${how}`);
    if (typeof id !== 'string' || !id) fail(`goal needs the task's id, as the order names it. ${how}`);
    const files = (existsSync(dir) ? readdirSync(dir) : []).filter((f) => GOAL_FILE.exec(f)?.[1] === goal).sort();
    if (!files.length) fail(`no goal file ${goal}-<slug>.md in ${dir}. ${how}`);
    if (files.length > 1) fail(`${goal} names ${files.length} files in ${dir} (${files.join(', ')}); give each goal its own number. ${how}`);
    const path = join(dir, files[0]);
    const order = parseOrder(readFileSync(path, 'utf-8'));
    if (order.edges.some((e) => e.from.task === id || e.to.task === id) || order.listed.some((r) => r.task === id)) return;
    const bad = order.invalid.length ? ` (${order.invalid.length} line(s) there could not be read: ${order.invalid.map((l) => `line ${l.line} ${l.reason}`).join('; ')})` : '';
    fail(`${id} is not in the ## 순서 section of ${path}${order.found ? '' : ', which has none'}${bad}. ${how}`);
}

export function runApiBoardWrite(command) {
    return (input = {}, env = process.env) => withBoard(input.team_name, async ({ store, roster, manifest }) => {
        const { team_name, by, ...args } = input;
        const actor = actorOf(env, team_name, roster, by);
        // a derived task serves its parent's request; anyone else's add is refused by the board as before
        if (command === 'add' && !args.parent && pmsOf(roster).includes(actor)) requireGoal(team_name, args);
        // a document task lands no commit, so its worker need not be in a repository (T158)
        // (R8 L1: `repo` is never the caller's, whatever the task turns out to be when the board reads it)
        if (command === 'land') {
            delete args.repo;
            if (!isDocument((await store.get('task', String(args.id))) ?? {})) args.repo = toplevel(manifest.workers.find((w) => w.name === actor).cwd);
        }
        return boardFor({ store, roster, manifest, actor })[command](args);
    }, { write: true });
}
