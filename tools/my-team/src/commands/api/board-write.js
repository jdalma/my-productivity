/**
 * `my-team api board-<command>` for the board's write commands (T63e; docs/board.md, Commands): add, assign,
 * take, note, land, verdict, finding, cancel, announce, wait, answer, ask, decision-edit, progress, edit. The worker acting is the one MY_TEAM_WORKER names
 * (`by` in the input from the user's shell). land's repository is the top level of the acting worker's cwd,
 * not an input; a document task's land has none.
 */

import { actorOf, boardFor, withBoard } from '../../board/compose.js';
import { isDocument } from '../../board/core/rules.js';
import { toplevel } from '../../board/git.js';

export function runApiBoardWrite(command) {
    return (input = {}, env = process.env) => withBoard(input.team_name, async ({ store, roster, manifest }) => {
        const { team_name, by, ...args } = input;
        const actor = actorOf(env, team_name, roster, by);
        // a document task lands no commit, so its worker need not be in a repository (T158)
        // (R8 L1: `repo` is never the caller's, whatever the task turns out to be when the board reads it)
        if (command === 'land') {
            delete args.repo;
            if (!isDocument((await store.get('task', String(args.id))) ?? {})) args.repo = toplevel(manifest.workers.find((w) => w.name === actor).cwd);
        }
        return boardFor({ store, roster, manifest, actor })[command](args);
    }, { write: true });
}
