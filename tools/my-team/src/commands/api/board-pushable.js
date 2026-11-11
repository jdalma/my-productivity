/**
 * `my-team api board-pushable` (T63f; docs/board.md, Push gate): whether every commit going out is covered —
 * in the commits of a landing an approve verdict covers, in this repository, or an ancestor of the
 * repository's baseline (reviewed before the board, or the user's own). Anything else is uncovered, named with
 * its subject. What cannot be judged is an error, never ok: the pre-push gate refuses on it.
 */

import { refuseOutsider, withBoard } from '../../board/compose.js';
import { approvedCommits } from '../../board/core/queries.js';
import { outgoingCommits, resolveCommit, subjectOf, toplevel, withinBaseline } from '../../board/git.js';

export function runApiBoardPushable(input = {}, env = process.env) {
    refuseOutsider(env, input.team_name);
    return withBoard(input.team_name, async ({ store }) => {
        const repo = toplevel(input.repo ?? process.cwd());
        const commits = outgoingCommits(repo, input);
        const baseline = input.baseline ? resolveCommit(repo, input.baseline) : null;
        const approved = await approvedCommits(store, repo);
        const uncovered = commits
            .filter((c) => !approved.has(c) && !(baseline && withinBaseline(repo, c, baseline)))
            .map((c) => ({ commit: c, short: c.slice(0, 7), subject: subjectOf(repo, c) }));
        return { ok: uncovered.length === 0, repo, covered: commits.length - uncovered.length, uncovered };
    });
}
