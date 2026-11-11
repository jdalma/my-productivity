/** `my-team api board-status` — the whole board, or one task's family (T63d, rfc/board-design.md §6.1). */

import { refuseOutsider, withBoard } from '../../board/compose.js';
import { status } from '../../board/core/queries.js';

export function runApiBoardStatus(input = {}, env = process.env) {
    refuseOutsider(env, input.team_name);
    return withBoard(input.team_name, async ({ store, roster }) => ({ ok: true, ...(await status(store, roster, { task: input.task })) }));
}
