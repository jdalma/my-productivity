/** `my-team api board-inbox` — the asking worker's own work, reviews, notes and announcements (T63d, §6.1). */

import { actorOf, withBoard } from '../../board/compose.js';
import { BoardError } from '../../board/core/rules.js';
import { inbox } from '../../board/core/queries.js';

export function runApiBoardInbox(input = {}, env = process.env) {
    const since = input.since ?? {};
    const seq = (v) => v === undefined || (Number.isInteger(v) && v >= 0);
    if (typeof since !== 'object' || Array.isArray(since) || !seq(since.note) || !seq(since.announcement)) {
        throw new BoardError('invalid', 'since must be {note, announcement} seqs, as the last cursor gave');
    }
    return withBoard(input.team_name, async ({ store, roster }) => {
        const worker = actorOf(env, input.team_name, roster, input.worker);
        return { ok: true, worker, ...(await inbox(store, roster, worker, since)) };
    });
}
