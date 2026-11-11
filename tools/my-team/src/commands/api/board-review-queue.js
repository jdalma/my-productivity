/** `my-team api board-review-queue` — the review requests the asking worker judges (T63d, §6.1, R64). */

import { actorOf, withBoard } from '../../board/compose.js';
import { reviewQueue } from '../../board/core/queries.js';

export function runApiBoardReviewQueue(input = {}, env = process.env) {
    return withBoard(input.team_name, async ({ store, roster }) => {
        const worker = actorOf(env, input.team_name, roster, input.worker);
        return { ok: true, worker, ...(await reviewQueue(store, roster, worker)) };
    });
}
