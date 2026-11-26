/**
 * `my-team solo` — a two-worker board team in the current folder, without a config file (T141).
 *
 * `dev` (orchestrator) takes the user's instructions in its pane and keeps every change on the board;
 * `reviewer` (worker) judges the board's review requests and cannot write to the repository. The config
 * goes through `start` unchanged: the same validation, the same refusal of a running team, the same launch.
 */

import { basename, join } from 'path';

import { getStateRootBase } from '../lib/state-root.js';
import { runStart } from './start.js';

/** `solo-<folder>` in the team name rule (lib/team-name.js): lower case, letters, digits and single hyphens. */
export function soloTeamName(cwd) {
    const slug = basename(cwd).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    if (!slug) {
        throw new Error(`The folder name '${basename(cwd)}' has no letter or digit a team name can use. Pass --name <team>.`);
    }
    return `solo-${slug}`.slice(0, 50).replace(/-+$/, '');
}

function devBrief(team) {
    const docs = `~/.my-team/docs/${team}/`;
    return [
        'You work for the user in this pane, one task at a time. The board is how the user follows the work: what is being done, how far it got, and how the review ended.',
        '',
        'When the user asks for a change to code or documents:',
        `1. Before editing, write a short ticket file under ${docs} with the goal, numbered items to do, and how to check the result.`,
        '2. Add it to the board with board-add: yourself (dev) as assignee, reviewer as reviewer, the ticket file as ticket, the current HEAD commit as base (board-land refuses a task without one), and "single":true (one request, one task; board-add refuses a task with no parent without it). Then start it with board-take.',
        '3. Each time you finish a numbered item, record it with board-progress.',
        `4. When the work is done, commit it, write a report under ${docs}, and submit it with board-land. The reviewer is told by the board.`,
        '5. A changes verdict: fix the findings, then board-take and board-land again with the fixed findings in closes.',
        '6. A decision only the user can make: put it on the board before you ask it in this pane, tied to the task it serves (board-wait when the task cannot go on without it, board-ask with tasks otherwise), one entry per decision. Record the answer with board-answer, and a decision the user made unasked with board-ask and answered.',
        '',
        'Do not add a task for work that changes no code or documents, such as answering a question or reading files.',
        'Write tickets, progress notes and reports in plain sentences, without abbreviations.',
    ].join('\n');
}

/**
 * How the reviewer reruns a check on the submitted commit, outside the folder it shares with dev. The guard reads the
 * command line: a path held in a shell variable is not known to be outside the repository, so the steps use the path
 * mktemp printed, and git archive, which needs no checkout.
 */
export const COPY_STEPS = [
    'Rerun the check on a copy of the submitted commit, never in the working folder you share with dev:',
    '1. Run `mktemp -d` on its own and read the folder it prints.',
    '2. `git archive <commit> | tar -x -C <that folder>`, with the folder written out, not in a shell variable: your repo-write rule refuses a git command it cannot place outside the repository.',
    '3. Run the check inside <that folder>.',
    'The copy has no .git: a check that needs a git repository can fail there for that reason alone. Name such a check in your verdict and do not count its failure against the submission.',
];

const REVIEWER_BRIEF = [
    'You review the work dev submits on the board, and nothing else. You cannot edit the repository, commit or push.',
    'When a board notice (kind board) arrives, take the request from board-review-queue, check the commit against its ticket, rerun its check, and judge with board-verdict.',
    ...COPY_STEPS,
    'Write findings in plain sentences, without abbreviations, each with a command that shows the problem.',
].join('\n');

/** The raw team config `start` validates: board on, the given claude arguments for both workers. */
export function soloConfig({ cwd, name, launchArgs = [], newWindow = false, detached = false }) {
    const team = name ?? soloTeamName(cwd);
    return {
        team_name: team,
        // ponytail: follows MY_TEAM_STATE_ROOT_BASE, which validateConfig's default does not
        state_root: join(getStateRootBase(), team),
        board: { store: 'sqlite' },
        solo: true,
        new_window: newWindow,
        detached,
        workers: [
            {
                name: 'dev', agent_type: 'claude', cwd, role: 'orchestrator',
                description: 'Works for the user in this pane; keeps every change on the board',
                extra_prompt: devBrief(team), launch_args: launchArgs,
            },
            {
                name: 'reviewer', agent_type: 'claude', cwd, role: 'worker',
                description: "Reviews dev's board submissions (read-only)",
                extra_prompt: REVIEWER_BRIEF, launch_args: launchArgs, deny: ['push', 'repo-write'],
            },
        ],
    };
}

export async function runSolo(launchArgs, opts, deps) {
    const teamConfig = soloConfig({
        cwd: process.cwd(), name: opts.name, launchArgs,
        newWindow: Boolean(opts.newWindow), detached: Boolean(opts.detached),
    });
    return runStart({ ...opts, teamConfig }, deps);
}
