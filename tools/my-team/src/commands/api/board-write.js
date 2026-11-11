/**
 * `my-team api board-<command>` for the board's write commands (T63e; docs/board.md, Commands): add, assign,
 * take, note, land, verdict, finding, cancel, announce. The worker acting is the one MY_TEAM_WORKER names
 * (`by` in the input from the user's shell). land's repository is the top level of the acting worker's cwd,
 * not an input.
 */

import { actorOf, boardFor, withBoard } from '../../board/compose.js';
import { toplevel } from '../../board/git.js';

export function runApiBoardWrite(command) {
    return (input = {}, env = process.env) => withBoard(input.team_name, async ({ store, roster, manifest }) => {
        const { team_name, by, ...args } = input;
        const actor = actorOf(env, team_name, roster, by);
        if (command === 'land') args.repo = toplevel(manifest.workers.find((w) => w.name === actor).cwd);
        return boardFor({ store, roster, manifest, actor })[command](args);
    });
}
