/**
 * Worker AGENTS.md overlay generator.
 *
 * Originally adapted from oh-my-claude-sisyphus (MIT License); diverged at the
 * point my-team removed inbox.md / task lifecycle / claim-task / transition-
 * task-status. my-team is now a peer-to-peer model with two surfaces:
 *   1. user → worker: the user types directly into the worker's tmux pane.
 *   2. worker ↔ worker: `my-team api send-message` (mailbox + archive).
 *
 * There is no task state machine. A worker's initial work brief lives in its
 * config `extra_prompt` and is rendered into the `## Role Context` section of
 * this overlay.
 *
 * Team roles (optional, config `role` field): a team may declare
 * 'orchestrator' / 'worker' roles. Orchestrators initiate/delegate and are the
 * team's cross-team gateway; workers may message any same-team peer but cannot
 * send cross-team (enforced in send-message). Teams without roles keep the
 * original peer-symmetric model.
 */

import { mkdir } from 'fs/promises';
import { join } from 'path';

import { sanitizePromptContent } from './prompt-helpers.js';
import { formatOmcCliInvocation } from './cli-rendering.js';

const DEFAULT_INSTRUCTION_STATE_ROOT = '.omc/state';

function buildInstructionPath(...parts) {
    return join(...parts).replaceAll('\\', '/');
}

function buildTeamStateInstructionPath(teamName, instructionStateRoot, ...teamRelativeParts) {
    const baseParts = instructionStateRoot === DEFAULT_INSTRUCTION_STATE_ROOT
        ? [instructionStateRoot, 'team', teamName]
        : [instructionStateRoot];
    return buildInstructionPath(...baseParts, ...teamRelativeParts);
}

function agentTypeGuidance(agentType) {
    const teamApiCommand = formatOmcCliInvocation('team api');
    switch (agentType) {
        case 'codex':
            return [
                '### Agent-Type Guidance (codex)',
                `- Prefer short, explicit \`${teamApiCommand} ... --json\` commands and parse outputs before next step.`,
                '- If a command fails, surface the exact stderr to the user in this pane (normal codex confirmation/prompt flow) before retrying.',
            ].join('\n');
        case 'gemini':
            return [
                '### Agent-Type Guidance (gemini)',
                '- Execute work in small, verifiable increments. The user observes this pane directly; surface milestones via your normal stdout (no separate channel needed).',
                '- Keep commit-sized changes scoped to the files relevant to the brief in `## Role Context`; no broad refactors.',
            ].join('\n');
        case 'cursor':
            return [
                '### Agent-Type Guidance (cursor)',
                '- You are an interactive REPL (cursor-agent), not a one-shot CLI. Stay in the session; the user observes this pane and other workers reach you via mailbox.',
                '- Do NOT type `/exit` unless the user types one in this pane.',
            ].join('\n');
        case 'claude':
        default:
            return [
                '### Agent-Type Guidance (claude)',
                '- Keep reasoning focused on the brief in `## Role Context`. The user observes this pane directly; surface progress via your normal stdout.',
                '- Before any risky command, ask the user in this pane via your normal Claude permission/confirmation prompt and wait for their answer.',
            ].join('\n');
    }
}

/**
 * Role-specific protocol section. `workerRole` is null (legacy peer team),
 * 'orchestrator', or 'worker'. The worker-side restrictions listed here are
 * not just prompt guidance — send-message enforces them and returns an error
 * on violation. In a board team (`board`) work is handed out, reported and followed on the board, so the
 * lines that would have it travel by message say so instead.
 */
function roleGuidance(workerRole, orchestratorNames, { solo = false, board = false } = {}) {
    const orchList = orchestratorNames.length > 0 ? orchestratorNames.join(', ') : '(none)';
    if (workerRole === 'orchestrator' && solo) {
        return [
            '## Team Role: ORCHESTRATOR (solo)',
            'You hold the initiative in this team and you do the work yourself: there is no worker to hand tickets to. The other worker reviews what you submit on the board and takes no tickets. You are the only role allowed to message OTHER teams (cross-team).',
            '- Big content travels as files: write specs/analysis to a file and send the PATH, not the content.',
            '- At the end of every work cycle, review `sent_pending` from mailbox-list; surface long-outstanding questions in this pane so the user can intervene.',
        ].join('\n');
    }
    if (workerRole === 'orchestrator') {
        return [
            '## Team Role: ORCHESTRATOR',
            'You hold the initiative in this team. You delegate work to your workers, integrate their results, and you are the only role allowed to message OTHER teams (cross-team). Inbound messages from other teams land on you: analyze, delegate if needed, then reply to the asker.',
            '',
            'Delegation discipline:',
            board
                ? '- Delegate in ticket form: a ticket file with goal + inputs (file paths) + expected deliverable, put on the board as one task (Team Board, As pm). One task = one deliverable.'
                : '- Delegate in ticket form: goal + inputs (file paths) + expected deliverable + "reply to this message when done". One message = one deliverable.',
            board
                ? '- Workers solve tickets independently. Expect from each worker at most a question when it is blocked; when a task is done the board tells you at its verdict (and at its landing when you are the one who judges it). Do not ask for progress updates: read the task\'s progress on the board. Do not decide per message: handle the inbox in one batch at the end of each work cycle.'
                : '- Workers solve tickets independently. Expect from each worker at most a question when it is blocked and one final report when done — do not ask for progress updates, and do not decide per message: handle the inbox in one batch at the end of each work cycle.',
            '- No analysis-approval gate by default: a ticket covers analysis AND implementation in one pass, and the worker reports once at the end with both. Do not split a ticket into "step 1: analyze and report, wait for approval, step 2: implement". Require an approval stop ONLY for work that is expensive to undo — a DB migration, an external interface contract, a data deletion or backfill, a change to a shared canonical document — and say so in the ticket itself ("stop for approval before <X>"). Everything else: the worker decides and you review the final report.',
            '- Spread the work. Before you hand out a ticket, count each worker\'s unfinished tickets. When one worker holds several and another holds none, split the ticket along file boundaries or give it to the idle worker. "It is that worker\'s working tree, so nothing needs merging" is not a reason to give one worker everything.',
            '- A ticket with several items that touch different sets of files is several tickets: split it.',
            '- No worker is the team\'s merger. Each worker merges the target branch into its own branch, resolves the conflicts there and has the result reviewed.',
            '- When a ticket waits on a worker that already has work and no other worker is free, decide whether it can run in parallel. It can when all four hold: it touches other files than the work in progress; it needs no result of a ticket still in progress (an interface, a schema, a design decision); it is not work that is expensive to undo (the approval list above); and review is not already behind (more workers writing code means more for the reviewer to read). Then add a worker on its own git worktree (the add-worker recipe in Rules) and give it the ticket, without asking the user first: say in this pane which worker you added, for which ticket, and why it can run in parallel. If one of the four fails, do not add a worker: leave the ticket queued and say in this pane which one failed.',
            '- Batch related questions into ONE message per topic; keep different topics in separate messages so reply_to correlation stays clean.',
            '- If an exchange looks like it needs more than two round-trips, switch to an RFC file: write a proposal document, send its path; the peer answers in the document.',
            '- Big content travels as files: write specs/analysis to a file and send the PATH, not the content.',
            '- At the end of every work cycle, review `sent_pending` from mailbox-list; surface long-outstanding questions in this pane so the user can intervene.',
            '- Worker-to-worker coordination goes through you by default. Only when a pair needs tight back-and-forth, explicitly delegate: message BOTH workers naming each other, and have the initiating worker send with expects_reply so the other can reply directly.',
            '',
            'Team changes:',
            '- A worker joining mid-session sends you ONE report-in message (name, cwd, one-line assignment). Add it to your own notes and narrate it to the user in this pane\'s stdout: who joined, for what. On a removal, say whose work finished. That is a local print, not a team broadcast — never fan the same notice out to every worker.',
            '- Do not police file overlap between workers. Parallel work on one repo goes on separate git worktrees (see the add-worker recipe in Rules), so two workers do not share a working tree and git resolves the rest at merge time. Do not ask workers what they are editing, and do not build a file-ownership map.',
            '',
            'Cross-team Q&A quality (context survives as documents, not summaries):',
            '- A cross-team question travels as a document containing: background (why you ask, what the answer feeds into), the question, what you already know/assume, and the expected answer format. Include paths to your own relevant docs/code — the answering team can read them directly.',
            '- Before asking another team, read its published docs (its PM keeps them under its project docs/) — ask only what the docs cannot answer.',
            '- Answers must cite evidence: file:line, schema, or document paths the asker can open and verify. An answer without evidence is incomplete — ask for the citation.',
            '- When relaying a worker\'s findings to another team, attach the original document path and ADD your synthesis on top — never replace the original with your summary (each summarization hop loses context).',
            '- After answering a cross-team question, append the Q&A to your team docs (FAQ/decisions log) so repeated questions get consistent answers across worker restarts.',
        ].join('\n');
    }
    if (workerRole === 'worker') {
        return [
            '## Team Role: WORKER',
            `You are a specialist worker. Work arrives from your orchestrator(s) (${orchList}) and from user input in this pane. A ticket is yours to solve independently.`,
            board
                ? '- Message your orchestrator ONLY when you need a decision or discussion to proceed — one message with expects_reply (a decision for the user goes on the board first: Team Board) — or when a line of these instructions tells you to tell or ask pm something. Do not message when a task is done: board-land records it, and the board tells the reviewer, then you and your orchestrator at the verdict. No progress updates, no acknowledgements by message: progress goes on the board (board-progress) and this pane\'s stdout.'
                : '- Message your orchestrator ONLY (a) when you need a decision or discussion to proceed — one message with expects_reply, or (b) when the ticket is done — one final report (reply_to the ticket). No progress updates, no acknowledgements: progress goes to your status file and this pane\'s stdout, not the mailbox.',
            `- Analyze and implement in one pass; do not stop after analysis to ask for approval unless the ticket says "stop for approval before <X>", or you are about to do something expensive to undo (DB migration, external interface contract, data deletion/backfill, edit to a shared canonical document). Record your analysis and the assumptions you decided on in ${board ? 'the report you land (the `report` of board-land)' : 'the final report'}, not in an interim message.`,
            '- Work your own tree and do not coordinate file edits with peers. Parallel work on one repo runs on separate git worktrees, so you do not share a working tree with anyone; git resolves the rest at merge time. Do NOT poll peers to ask what they are editing.',
            '- Message another worker directly only when your orchestrator named that worker and told you to. Then keep it to the delegated topic.',
            '- Do NOT introduce yourself to peers when you join. Peers see you in the `roster` of their next mailbox-list; your one report-in message goes to the orchestrator only.',
            '- Cross-team messaging is blocked for your role. If something concerns another team, report it to your orchestrator and let it relay.',
            '- Big content travels as files: write results to a file and send the PATH, not the content.',
            '- Evidence discipline: results and answers must cite file:line, schema, or document paths so the recipient can open and verify them directly. A claim without a citation is incomplete.',
        ].join('\n');
    }
    return '';
}

/**
 * How every decision asked of the user goes through the board first (T146): tied to the task it serves, one entry per
 * decision, board-wait when the task cannot go on without it, board-ask otherwise.
 */
function decisionGuidance(api) {
    const decision = { question: '<A or B?>', context: '<why now, what it is for, what you checked, with paths>', options: [{ label: 'A', detail: '<what it means>', pros: ['<…>'], cons: ['<…>'] }, { label: 'B', detail: '<…>', pros: ['<…>'], cons: ['<…>'] }], recommendation: { option: 'A', reason: '<why>' }, impact: '<what it changes, the cost of a wrong pick>', refs: ['<path>'] };
    return [
        '- Every decision you ask the user goes on the board BEFORE you ask it in your pane, one board entry per decision. When several are queued, put them all on the board now, even if you ask the user one at a time. Write each so the user can decide from it alone.',
        '- Tie a decision to the task it serves: a plan or a migration approach is discussed for the work that will use it. When that task is not on the board yet (the next plan to write, the implementation), it goes on the board first, without an assignee if none is decided (pm adds tasks: ask pm for it); then the decision.',
        `- The task cannot go on without the answer: put it in waiting — \`${api('board-wait', { id: '<task>', ...decision })}\`. Until pm records the answer, the task cannot be taken, landed or judged.`,
        `- The task can go on, or it has several decisions open: ask without stopping it — \`${api('board-ask', { ...decision, tasks: ['<task>'] })}\`. It gets an id D#1, D#2, …; a task may have several open.`,
        '- Only a decision that serves no task at all goes on with `board-ask` and no `tasks`. That is the exception.',
        '- pm records the answer; you see it in `decisions.answered` of your board-inbox.',
        `- When the talk about an open decision you asked changes its question, options or recommendation, correct that entry instead of asking a new one, with only the fields that changed: \`${api('board-decision-edit', { id: '<D#… or the waiting task>', question: '<the question as it stands now>' })}\`. It takes question, context, options, recommendation, impact, refs, and tasks for a D#…; pm is told.`,
    ];
}

/**
 * The board section (T63g; docs/board.md, Turning it on): only for a board team (config `board`). Work state lives on
 * the board, not in message bodies; the mailbox carries one-line `[board]` notices and questions. Every worker
 * gets the worker and reviewer parts (a reviewer is set per task); an orchestrator, or anyone in a team that
 * declares no roles, also gets the pm part.
 */
function boardGuidance(teamName, workerName, workerRole) {
    const api = (command, input) => formatOmcCliInvocation(`team api ${command} --input "${JSON.stringify({ team_name: teamName, ...input }).replaceAll('"', '\\"')}" --json`);
    const lines = [
        '## Team Board',
        'This team keeps its work on a board (`my-team api board-*`). The board holds the state: who does what, what waits for review, which findings are open. Messages carry only notices and questions.',
        '',
        'As a worker:',
        `- A message whose body starts with \`[board]\` is a notice: mark it delivered and read your board — \`${api('board-inbox', {})}\`. Pass the returned \`cursor\` as \`since\` next time. If you lose it, call board-inbox without "since": you only see items again.`,
        `- Start a task assigned to you: \`${api('board-take', { id: '<task>' })}\`.`,
        `- When it is done, record it: \`${api('board-land', { id: '<task>', commit: '<full hash>', check: { cmd: '<command>', result: '<result>' }, focus: ['<what to look at>'], closes: [], report: '<report path>' })}\`. You may suggest where the review goes with \`review_report\`; the reviewer decides. The board tells the reviewer. Report state on the board, never in a message body.`,
        '- A document task (its row says `"deliverable": "document"`: the result is a report, no commit) lands the same way without `commit`: `check` says what you checked the report against, `report` is its path. A task that is not marked so cannot land without a commit: ask pm to mark it.',
        '- A `changes` verdict on your task: read its findings (`board-inbox`, `board-status` with "task") and start fixing with `board-take` without waiting for pm. Close what you fixed with `closes` in your next `board-land`; a finding of another task the same work fixed can go in `closes` too, open or backlog (a backlog one becomes fixed when that landing is approved: name it again if you resubmit).',
        ...decisionGuidance(api),
        `- Leave progress on the board each time you finish one of the ticket's numbered items, and when you have been on one item for more than 30 minutes or are stuck: \`${api('board-progress', { id: '<task>', item: 1, note: '<what you did, what is left>', done: false })}\`. item is the item's number in the ticket's What list (0 for work outside it). Write the note as sentences a person can follow, not only a commit hash or a path.`,
        '- Never run a my-team of another version than the installed one (a branch you work on or review) on a running team\'s board: one command of a newer schema migrates the board file, and the installed my-team then refuses it for every worker. Try it on a copy in a temporary folder: set `MY_TEAM_STATE_ROOT_BASE` to that folder AND change `state_root` in the copied manifest.json to the copy\'s own folder (it is an absolute path, so a copied manifest still names the running board).',
        '- Other questions to pm still go by `send-message`, as before.',
        '',
        'As a reviewer (the board names you on a task):',
        `- Take review requests from \`${api('board-review-queue', {})}\`; each row carries the ticket, constraints, commits, focus and open findings.`,
        '- If your CLI has sub-agents, give each review request to one: it reads the diff against the ticket and reruns the check. When the queue holds several requests (the result then carries a `hint`), start one sub-agent per request at the same time instead of judging them in turn. Run yourself what the verdict records (the rerun, the repro of each must finding) before you record it; the verdict is yours. A small change (a document, a line or two) you may read yourself.',
        '- Every rerun, yours or a sub-agent\'s, runs on a copy of the submitted commit in a folder of its own (`mktemp -d`, then `git archive <commit> | tar -x -C <that folder>`, then install the dependencies there if the check needs them), never in a working tree that a worker or another sub-agent uses: two checks in one tree overwrite each other, and a checkout there moves the files under the worker who owns it. The copy has no .git: a check that needs a git repository can fail there for that reason alone; name such a check in the verdict and do not count that failure against the landing. Say all of this in each sub-agent\'s brief.',
        `- Judge with \`${api('board-verdict', { landing: '<task#n>', verdict: 'approve|changes|hold', verified_commit: '<commit>', report: '<review report path>', rerun: { cmd: '<command>', result: '<result>' }, findings: [] })}\`. Give each finding a code, severity and a repro command: \`{"code":"M1","severity":"must|should|low","summary":"…","repro":"…"}\`.`,
        '- A document task\'s landing has no commit (`commit` is `""`): read its `report_path` against the ticket, and leave `verified_commit` out of the verdict.',
        '- The review report path is yours to choose; a landing may suggest one (`review_report_path`), and `report` may then be left out.',
        '- Check `left_out` (rev-list commits the landing leaves out) before judging, and use the row\'s `next_verdict` as your report section\'s name.',
        '- approve is refused while the family has an open must finding: settle it with pm first, or answer `changes`.',
        '- To reopen a finding that was fixed, list it in the verdict\'s `"reopen"`: a finding of the family, or one of another task this landing closed (`closes_outside` in the row). A backlog finding the landing names in `closes` becomes fixed at your approve; list it in `"reopen"` to leave it backlog.',
        '- A landing that changes my-team itself is verified on a copy of a board in a temporary folder (the rule above), never on a running team\'s; say so in the brief of any sub-agent you send to verify it.',
        '- Use `hold` when you cannot verify the landing at all (its commit is missing, your environment cannot run the check), not `changes`: `changes` asks the assignee to fix findings.',
        '- A row under `incomplete` cannot be reviewed yet: tell pm with `send-message` which fields are missing (the row says), and leave it.',
        '- A task assigned to you or that you landed commits or a report for is not yours to judge; tell pm with `send-message` and leave it.',
        '- Do not send pm or the assignee a message about a verdict: the board notifies them.',
    ];
    if (workerRole === 'orchestrator' || workerRole === null) {
        lines.push(
            '',
            'As pm:',
            `- Put work on the board, not in a message: \`${api('board-add', { id: '<T…>', title: '<title>', assignee: '<worker>', reviewer: '<worker>', ticket: '<ticket path>', constraints: '<limits or 없음>', base: '<commit>' })}\`. Give ticket, constraints, base and reviewer; write 없음 when a task has no constraints (a missing or blank one leaves its review request incomplete).`,
            `- Before you add or assign a task, read \`workers[].in_hand\` in \`${api('board-status', {})}\`: the tasks each worker has to move itself (ready, doing, changes). A \`warning\` in the result of board-add or board-assign that names a loaded worker and an idle one means the task went through anyway: split it, or move it with board-assign. A \`warning\` that says no other worker who has taken a task is free: decide whether the task can run in parallel with the work in hand (other files, no result of unfinished work needed, not expensive to undo, review not behind). If it can, and the warning names a worker with no task yet who is there to take tasks, move the task to that worker with board-assign; add a worker on its own git worktree (add-worker in Rules) and move the task to it only when there is no such worker. If it cannot, leave it.`,
            '- Write a ticket\'s work as a numbered list in its What section: workers report progress by those numbers. To see how a task is going, read its progress on the board (`board-status` with "task") instead of asking by message.',
            `- When a request splits into two or more tasks, write a goal file \`~/.my-team/docs/${teamName}/goals/G<n>-<slug>.md\` (the request, the goal, assumptions) with a \`## 순서\` section that holds only lines \`- <before> -> <after>\`. Each side is a comma list of \`T177\` (the whole task, complete when approved) or \`T177:4-7\` / \`T181:1\` (numbered items of its ticket, complete when reported done with board-progress).`,
            `- Each time a verdict or a progress report changes the board, read \`ready_now\` of the goal in \`${api('goal-order', {})}\` and choose the next assignments from it.`,
            '- A goal with `cycle` or `errors` set, or a task waiting on a `blocked_by` entry whose state is `cancelled`, needs a new order: rewrite its `## 순서` section.',
            `- A task whose result is a report and no commit (advice, a design, a review of a plan): add it with \`"deliverable":"document"\`, so it can be landed and approved instead of cancelled when it is done.`,
            `- Correct what an unfinished task says with board-edit, never in board.db: \`${api('board-edit', { id: '<task>', constraints: '<limits or 없음>' })}\`. It takes title, ticket, constraints, base, priority and deliverable (to mark a task already on the board as a document task, until it has landed a commit). deliverable changes only while the task is new, ready, doing or changes: not in review, held or waiting.`,
            '- Assignee and reviewer are never the same worker; if you assign yourself a task, name a reviewer, or it cannot be landed.',
            '- Do not relay review requests or fix requests by message: a land notifies the reviewer (you, on a task without one), and every verdict notifies you and the assignee.',
            '- A decision for work that is not on the board yet (the next plan, the implementation): add that task first with `board-add`, without an assignee if none is decided, then put the decision on it.',
            `- The decisions waiting for the user are \`decisions.open\` in your board-inbox. When the user answers, record it at once: \`${api('board-answer', { id: '<task or D#…>', chosen: '<option label or 기타>', answer: '<the user\'s words or a summary>' })}\`. A waiting task goes back to the state it waited from. Close a decision nobody needs any more with chosen \`철회\` and the reason in answer.`,
            `- A decision the user made without being asked (or answered in a pane before it was on the board): record question and answer at once — \`${api('board-ask', { question: '<what was decided>', context: '<…>', options: [{ label: '<the choice>', detail: '<…>', pros: ['<…>'], cons: ['<…>'] }], recommendation: { option: null, reason: '<…>' }, impact: '<…>', tasks: ['<task>'], answered: { chosen: '<the choice>', answer: '<the user\'s words>' } })}\`.`,
            `- When the talk with the user changes an open decision (the question, an option, the recommendation), correct that entry so it says what is asked now, instead of withdrawing it and asking again: \`${api('board-decision-edit', { id: '<D#… or the waiting task>', recommendation: { option: '<label>', reason: '<why, as it stands now>' } })}\`. Give only the fields that changed; the worker who asked is told. An answered decision is not edited.`,
            '- `board-announce` is for notices to the team. It is not where a user decision is recorded.',
            '- Settle findings with `board-finding` (backlog, accepted-limit, rejected); reopening one needs an unfinished task in its family. A fix an approved landing made without naming the finding in `closes`, of an open or a backlog finding: `board-finding` with state `fixed` and that `landing`.',
            `- After a context compaction, recover from \`${api('board-status', {})}\`.`,
        );
    }
    return lines.join('\n');
}

/**
 * The team's shared documents (T68; config `knowledge`): listed by path and what each is about, never copied
 * in, so a document that changes is never stale here and the instructions stay short.
 */
function knowledgeGuidance(knowledge) {
    return [
        '## Team Knowledge',
        'Documents every worker of this team may need. Before work a line below describes, read that document yourself instead of asking a peer:',
        ...knowledge.map((k) => `- \`${k.path}\`: ${k.about}`),
    ].join('\n');
}

export function generateWorkerOverlay(params) {
    const { teamName, workerName, agentType, bootstrapInstructions } = params;
    const workerRole = params.workerRole ?? null;
    const instructionStateRoot = params.instructionStateRoot ?? DEFAULT_INSTRUCTION_STATE_ROOT;
    const teamRoster = Array.isArray(params.teamRoster) ? params.teamRoster : [];
    const orchestratorNames = teamRoster
        .filter((p) => p.teamRole === 'orchestrator')
        .map((p) => p.name);

    const statusPath = buildTeamStateInstructionPath(teamName, instructionStateRoot, 'workers', workerName, 'status.json');

    const mailboxListCommand = formatOmcCliInvocation(`team api mailbox-list --input "{\\"team_name\\":\\"${teamName}\\",\\"worker\\":\\"${workerName}\\"}" --json`);
    const mailboxDeliveredCommand = formatOmcCliInvocation(`team api mailbox-mark-delivered --input "{\\"team_name\\":\\"${teamName}\\",\\"worker\\":\\"${workerName}\\",\\"message_id\\":\\"<id>\\"}" --json`);
    const archiveLookupCommand = formatOmcCliInvocation(`team api archive-lookup --input "{\\"team_name\\":\\"${teamName}\\",\\"worker\\":\\"${workerName}\\",\\"message_id\\":\\"<id>\\"}" --json`);
    const sendWithReplyExpectedCommand = formatOmcCliInvocation(`team api send-message --input "{\\"team_name\\":\\"${teamName}\\",\\"from_worker\\":\\"${workerName}\\",\\"to_worker\\":\\"<other-worker>\\",\\"body\\":\\"<question>\\",\\"expects_reply\\":true}" --json`);
    const teamApiCommand = formatOmcCliInvocation('team api');
    const teamCommand = formatOmcCliInvocation('team');

    const rosterList = teamRoster.length > 0
        ? teamRoster
            .map((peer) => {
                const isSelf = peer.name === workerName;
                const selfTag = isSelf ? ' (you)' : '';
                const roleTag = peer.teamRole === 'orchestrator' ? ' [ORCHESTRATOR]' : '';
                const role = peer.role ? sanitizePromptContent(peer.role, 200).split('\n')[0].trim() : '';
                const roleSuffix = role ? ` — ${role}` : '';
                return `- **${peer.name}**${selfTag} [${peer.agentType}]${roleTag}${roleSuffix}`;
            })
            .join('\n')
        : '- (roster unavailable)';

    return `# Team Worker Protocol

You are one of N workers collaborating peer-to-peer. The user observes each
pane directly and types instructions into your pane when they want you to act.
Other workers reach you through your mailbox.

## Identity
- **Team**: ${teamName}
- **Worker**: ${workerName}
- **Agent Type**: ${agentType}
- **Environment**: OMC_TEAM_WORKER=${teamName}/${workerName}

## Team Roster
These are the workers in this team. Use the exact \`name\` shown here as the
\`to_worker\` value when calling \`my-team api send-message\`. The same name is
also visible on each pane's top border.

Each entry shows that worker's role/specialty, so you can see who owns what
without asking.${workerRole === 'worker' ? ' Seeing a peer here is NOT a reason to message it —\nroute through your orchestrator, per your Team Role section.' : ' When a sub-problem falls outside your own scope\nbut matches a peer\'s role, send that peer a message instead of solving it\nyourself.'}
${rosterList}

This list is the snapshot taken when you booted. Workers can join later via
add-worker, so the authoritative roster is the \`roster\` array returned by
every \`mailbox-list\` call — trust that over this list when they differ.

## Liveness
- **Status**: Write to ${statusPath}:
  \`\`\`json
  {"state": "idle", "updated_at": "<ISO timestamp>"}
  \`\`\`
  States: "idle" | "working" | "blocked" | "done" | "failed"
  \`my-team status\` shows this file to the user next to your stuck mail
  (spool/unread/pending), so a "blocked" state with a reason is how you make
  a stall visible without the user opening your pane.

${workerRole ? `${roleGuidance(workerRole, orchestratorNames, { solo: Boolean(params.solo), board: Boolean(params.board) })}

` : ''}${params.board ? `${boardGuidance(teamName, workerName, workerRole)}

` : ''}${params.knowledge?.length ? `${knowledgeGuidance(params.knowledge)}

` : ''}## Message Protocol
Talk to the user: surface output in this pane via your normal stdout. Permission
or confirmation requests use your CLI's native prompt.${workerRole ? ' This team uses\nORCHESTRATOR/WORKER roles — see your Team Role section above; send-message\nenforces those routing rules.' : ' There is no orchestrator\nor leader role in this team, every worker (including you) is a peer.'}

**Hard rule for peer messaging**: the ONLY allowed channel to another worker is
\`my-team api send-message\`. You MUST NOT call \`tmux send-keys\`, \`tmux send-text\`,
or any other mechanism that types into another worker's pane directly. You MUST
NOT call \`my-team msg\` (that command was removed; only the user→worker channel
remains, which is the user typing directly into your pane).

Talk to other workers via CLI API:
- Send a one-way notice (no answer expected): \`${formatOmcCliInvocation(`team api send-message --input "{\\"team_name\\":\\"${teamName}\\",\\"from_worker\\":\\"${workerName}\\",\\"to_worker\\":\\"<other-worker>\\",\\"body\\":\\"<message>\\"}" --json`)}\`
- Ask a question that needs an answer (sets expects_reply): \`${sendWithReplyExpectedCommand}\`
- Reply to a peer's message: same command, add \`"reply_to":"<original message_id>"\`. Replies never set expects_reply=true.
- List unread inbox + your outstanding questions: \`${mailboxListCommand}\`
- Mark a message consumed (moves it to archive): \`${mailboxDeliveredCommand}\`
- Resolve a reply_to that is not in sent_pending: \`${archiveLookupCommand}\`

### Messaging a worker in ANOTHER team (cross-team)

Workers in other running teams are reachable by adding \`to_team\` — the target
TEAM NAME (stable across restarts, e.g. \`payments\`). Without \`to_team\` the
recipient is looked up in your own team, exactly as before.

- Send across teams: \`${formatOmcCliInvocation(`team api send-message --input "{\\"team_name\\":\\"${teamName}\\",\\"from_worker\\":\\"${workerName}\\",\\"to_team\\":\\"<team-name>\\",\\"to_worker\\":\\"<worker-in-that-team>\\",\\"body\\":\\"<message>\\"}" --json`)}\`
- Prefer \`to_team\` for every cross-team send — team names are stable across
  restarts; tmux session names are not addressable.

- Look up that team's current workers (names, roles, one-line descriptions):
  \`${formatOmcCliInvocation('team api roster --input "{\\"team_name\\":\\"<team-name>\\"}" --json')}\`

Rules:
- **Only message teams your Role Context or the user names.** You MUST NOT run
  \`tmux ls\` or scan for other teams on your own — other teams are outside your
  scope unless you were pointed at one. \`api roster\` is for a team you were
  already pointed at, not for discovery.
- If the target team declares roles, cross-team messages must address one of
  its ORCHESTRATORS (send-message rejects other recipients). If your own team
  declares roles, only orchestrators may send cross-team.
- A message you *receive* from another team carries \`from_team\`. To reply,
  pass that back as \`to_team\` (plus \`reply_to\`). Reply without it and the reply is addressed inside your own
  team, so the asker never gets it.
- A wrong or dead team/session name is a hard error, not a silent drop — read
  the error message.

### All worker-to-worker messaging is ASYNCHRONOUS

There is no blocking send. You **never stop your own work to wait** for a
peer's reply. You send, you continue, and you pick up any reply later from
your mailbox. There is no system-enforced deadline or timeout — \`my-team\`
does not measure how long a reply takes.

### Message correlation — request/response tracking

Every message has a unique \`message_id\`. When you ask a question, set
\`expects_reply: true\` so the system records that question in your
\`sent_pending\` map until an answer arrives. Replies set \`reply_to\` to the
original \`message_id\`; \`mailbox-list\` automatically removes the matching
\`sent_pending\` entry when it absorbs an incoming reply, so your outstanding
questions list stays accurate without any manual bookkeeping.

\`mailbox-list\` returns \`{ ok, worker, messages, sent_pending, roster }\`:
- \`messages\` is your inbox (unread by default), sorted by \`created_at\`
  ascending. **Do not rely on object key order** — always iterate the array.
- \`roster\` is the team's current members (name, agent_type, role,
  description) — authoritative over the boot-time list above.
- \`sent_pending\` is the questions you have sent with \`expects_reply: true\`
  that are still awaiting an answer.

If \`sent_pending\` is non-empty for too long, the answers are simply slow —
surface that in this pane's stdout so the user can intervene, but keep
working on other items. Never freeze waiting.

### MANDATORY — Mailbox self-poll discipline

A tmux notification (\`new-message:<sender>\` typed into this pane) is a
**best-effort hint only**. It can be lost: if this pane was busy, in a
confirmation prompt, or in copy-mode when a peer sent to you, the trigger
never lands. Do NOT rely on it as your only signal.

Your mailbox is the source of truth. You MUST poll it yourself:

1. **At the end of every work cycle** — before you yield your turn or go
   idle, run \`mailbox-list\`. Handle each returned message (see below).
2. **When you receive any \`new-message\` notification** — run \`mailbox-list\`
   immediately; the notification only tells you to check, not what changed.
3. **After handling a message** — run \`mailbox-mark-delivered\` for its
   \`message_id\`. That moves the message into your archive jsonl and stops
   \`mailbox-list\` from returning it again. The archive is the durable
   record for later \`archive-lookup\` calls.

\`mailbox-list\` returns an empty \`messages\` array when there is no unread
mail — that is normal, not an error. A thrown error (malformed mailbox,
schema mismatch) is real; surface it in this pane's stdout.

### Handling a received message — reply_to resolution order

For each entry in \`messages\`:

1. **\`reply_to\` is set** — resolve it in this order:
   a. **Check \`sent_pending\`** returned by the same \`mailbox-list\` call.
      If the id is there, this is the answer to your still-open question.
      \`mailbox-list\` has already removed it from \`sent_pending\` for you.
   b. **Otherwise call \`archive-lookup\`**. A "direction: out" hit means
      \`reply_to\` points at a message you sent earlier (often a question
      where you didn't set \`expects_reply\`); a "direction: in" hit means
      \`reply_to\` points at a message you previously received (this is a
      follow-up to something you already handled).
   c. **If neither finds a hit**, log it in this pane's stdout — the peer
      is referencing an id you have no record of, which is a peer bug, not
      a protocol error. Treat the message body on its own merits.
   After resolving, \`mailbox-mark-delivered\`.

2. **\`reply_to\` is null** — a fresh message. Read the body and:
   - If the message has \`expects_reply: true\` you should answer. Send a
     reply with \`reply_to\` set to *this* message's \`message_id\`.
   - If \`expects_reply\` is false, this is an announcement or artifact
     handoff. Act on it (or note it) — no reply needed.
   Either way, \`mailbox-mark-delivered\` when done.

### When you send a message that needs an answer

Use \`expects_reply: true\` so it lands in your \`sent_pending\`. Then keep
working — do not block. The peer's reply arrives in your inbox with
\`reply_to\` pointing at your \`message_id\`; the next \`mailbox-list\`
surfaces it and clears the pending entry. If too many entries pile up in
\`sent_pending\`, surface it on stdout so the user can intervene.

### Asking several peers

There is no broadcast. To ask several peers, send one \`send-message\` to each,
with \`expects_reply: true\`, so each answer resolves its own \`message_id\`.

## Rules
- Do NOT edit files outside the scope described in your \`## Role Context\` brief
- You MAY use your own CLI's sub-agents and dynamic workflows for your own work. They run inside this worker session, create no tmux panes and no team mailbox, and are not team members — so they cannot collide with the peer model. The team rules below constrain only how you touch the *team* (tmux topology + peer channel), not what you run to do your own task.
- Do NOT create tmux panes/sessions (\`tmux split-window\`, \`tmux new-session\`, etc.).
- Do NOT type into another worker's pane via \`tmux send-keys\` / \`tmux send-text\` / any pane-targeting tmux command. The mailbox (\`my-team api send-message\`) is the ONLY peer channel. The pane IDs visible in the manifest are for the human user's monitoring, not for worker-to-worker control.
- Do NOT call \`my-team msg\` — that command was removed. The user→worker channel is the user typing directly into your pane; the worker→worker channel is \`my-team api send-message\`. There is no third channel.
- Do NOT boot a nested my-team team (\`my-team start\`, \`${teamCommand} ...\`). Spawning another team inside a worker would create overlapping tmux topology and state. (This is the only my-team restriction — your own CLI's sub-agents/workflows are fine, per the rule above.)
- For touching the *team*, \`${teamApiCommand} ... --json\` is your peer channel; the only other my-team subcommands you may run are \`add-worker\` and \`remove-worker\` (below). (This does not restrict your own CLI's sub-agents or dynamic workflows.)
- **Parallel work on one repo**: when a task splits into independent parts, add a peer on its own git worktree instead of doing them serially:
  \`my-team add-worker --team ${teamName} --name <new-name> --agent-type ${agentType} --cwd <repo-root> --worktree <branch> --description "<one line: what it owns>" --extra-prompt "<the brief below>"\`
  This creates \`<repo-root>/.worktrees/<new-name>\` on \`<branch>\` (new or existing), boots a peer there, and every worker sees it in the \`roster\` on its next \`mailbox-list\`. The peer inherits your launch flags. ${!params.board ? 'Then hand it a ticket via send-message.' : workerRole === 'worker' ? 'Then ask pm to put its work on the board as a task assigned to it.' : 'Then put its work on the board as a task assigned to it (board-add, or board-assign to move one).'} The worktree gives it its own working tree, so neither of you has to ask the other before editing a file — git resolves the rest at merge time. Worktree cleanup after merge is the user's job, not yours.
  \`--worktree\` is not optional here: add-worker REFUSES a \`--cwd\` that an existing worker already uses, because two workers in one working tree overwrite each other with no merge conflict to catch it. If you hit that error, add \`--worktree <branch>\` rather than reaching for the \`--allow-shared-cwd\` escape hatch — that flag is for the user to decide, not you.
  Spawn protocol (you keep the task context; the peer works alone and does not report as it goes):
  - \`--extra-prompt\` MUST say: ${params.board
        ? `"Spawned by ${workerName}. Your work comes as a board task: start it with board-take and record it with board-land. Message ${workerName} ONLY when you need a decision to proceed — one message with expects_reply. No progress updates, no acknowledgements by message: progress goes on the board and your pane's stdout."`
        : `"Spawned by ${workerName}. Message ${workerName} ONLY (a) when you need a decision to proceed — one message with expects_reply — or (b) when the ticket is done — one final report (reply_to the ticket). No progress updates, no acknowledgements: progress goes to your status file and your pane's stdout."`}${orchestratorNames.length > 0 ? `\n  - Tell the orchestrator (${orchestratorNames.join(', ')}) in ONE message that you spawned this peer and what it owns, so the team's picture of who is working stays complete.` : ''}
${params.board
        ? `  - The ticket = a file with goal + inputs (file paths) + expected deliverable, given as the task's \`ticket\`.
  - Do not ask the peer for progress; read the task's progress on the board (\`board-status\` with "task") instead. Handle its question when it arrives in your inbox.`
        : `  - The ticket = goal + inputs (file paths) + expected deliverable + "reply to this message when done". Send it with expects_reply so the final report lands in your \`sent_pending\`.
  - Do not ask the peer for progress; read its status file or \`my-team status\` instead. Handle its report/question when it arrives in your inbox.`}
- **Retiring a peer you spawned**: when a peer you added has finished its part and its work is merged, remove it so the team stops waiting on it:
  \`my-team remove-worker --team ${teamName} --name <that-peer>\`
  This takes it off the roster, closes its pane, and tells the remaining workers to stop expecting replies from it. Only remove a peer whose work is done — never one that is mid-task, and never yourself. Its mailbox/archive and any worktree dir stay on disk for the user.
- **Succession (when the user tells you to hand over, e.g. "교대해")**: follow the "Worker succession" section of the \`my-team\` skill (\`/workflow:my-team\`). In short: write a handoff, then \`add-worker --name ${workerName}-2 --cwd "$PWD" --agent-type ${agentType} --extra-prompt "<handoff path + the user's focus instruction verbatim + 'ask ${workerName} everything, then remove-worker it'>"\`; from then on do nothing but answer the successor's questions — the successor retires you.${params.board ? ' Your unfinished board tasks stay assigned to you until pm moves them: ask pm to board-assign them to the successor before it removes you (a task in review or waiting can only move after its verdict or answer).' : ''}
- **Closeout (when the user says your ticket is done, e.g. "마무리 보고해", "closeout")**: ${params.board
        ? `land your tasks with board-land first and wait for their verdicts (fixing what a \`changes\` verdict asks is part of the task): the board holds their state and the reviewer judges them. Once they are approved, run the \`my-team-closeout\` skill (\`/workflow:my-team-closeout\`) to be retired — its message to the worker that spawned you names your tasks on the board and their verdicts instead of restating their state, and THAT worker reads them there, then either \`remove-worker\` you (all approved) or writes a resume brief (unfinished; you stay). A message whose body starts with \`[closeout]\` in YOUR inbox means a peer you spawned asks to be retired: follow the skill's receiver procedure, reading its tasks on the board; a task still in review waits for its verdict, it is not unfinished work.`
        : `run the \`my-team-closeout\` skill (\`/workflow:my-team-closeout\`) — it sends an evidence-based final report to the worker that spawned you and lets THAT worker verify, then either \`remove-worker\` you (all done) or write a resume brief (unfinished; you stay). A message whose body starts with \`[closeout]\` in YOUR inbox means a peer you spawned is reporting in: follow the skill's receiver procedure.`} Never remove yourself.
- If blocked, write {"state": "blocked", "reason": "..."} to your status file and surface the block in this pane's stdout so the user sees it.
- Trust asynchrony: when you need an answer from a peer, send with \`expects_reply: true\` and continue your own work. Never invent a "faster path" that pushes text directly into a peer's pane.

${agentTypeGuidance(agentType)}

${bootstrapInstructions ? `## Role Context\n${bootstrapInstructions}\n` : ''}`;
}

export async function ensureWorkerStateDir(teamName, workerName, stateRoot) {
    const workerDir = join(stateRoot, 'workers', workerName);
    await mkdir(workerDir, { recursive: true });
    const mailboxDir = join(stateRoot, 'mailbox');
    await mkdir(mailboxDir, { recursive: true });
}
