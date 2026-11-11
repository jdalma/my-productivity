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
 * on violation.
 */
function roleGuidance(workerRole, orchestratorNames) {
    const orchList = orchestratorNames.length > 0 ? orchestratorNames.join(', ') : '(none)';
    if (workerRole === 'orchestrator') {
        return [
            '## Team Role: ORCHESTRATOR',
            'You hold the initiative in this team. You delegate work to your workers, integrate their results, and you are the only role allowed to message OTHER teams (cross-team). Inbound messages from other teams land on you: analyze, delegate if needed, then reply to the asker.',
            '',
            'Delegation discipline:',
            '- Delegate in ticket form: goal + inputs (file paths) + expected deliverable + "reply to this message when done". One message = one deliverable.',
            '- Workers solve tickets independently. Expect from each worker at most a question when it is blocked and one final report when done — do not ask for progress updates, and do not decide per message: handle the inbox in one batch at the end of each work cycle.',
            '- No analysis-approval gate by default: a ticket covers analysis AND implementation in one pass, and the worker reports once at the end with both. Do not split a ticket into "step 1: analyze and report, wait for approval, step 2: implement". Require an approval stop ONLY for work that is expensive to undo — a DB migration, an external interface contract, a data deletion or backfill, a change to a shared canonical document — and say so in the ticket itself ("stop for approval before <X>"). Everything else: the worker decides and you review the final report.',
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
            '- Message your orchestrator ONLY (a) when you need a decision or discussion to proceed — one message with expects_reply, or (b) when the ticket is done — one final report (reply_to the ticket). No progress updates, no acknowledgements: progress goes to your status file and this pane\'s stdout, not the mailbox.',
            '- Analyze and implement in one pass; do not stop after analysis to ask for approval unless the ticket says "stop for approval before <X>", or you are about to do something expensive to undo (DB migration, external interface contract, data deletion/backfill, edit to a shared canonical document). Record your analysis and the assumptions you decided on in the final report, not in an interim message.',
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
 * The board section (T63g, rfc/board-design.md §7): only for a board team (config `board`). Work state lives on
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
        '- A `changes` verdict on your task: read its findings (`board-inbox`, `board-status` with "task") and start fixing with `board-take` without waiting for pm. Close what you fixed with `closes` in your next `board-land`.',
        '- Questions and decision requests still go by `send-message`, as before.',
        '',
        'As a reviewer (the board names you on a task):',
        `- Take review requests from \`${api('board-review-queue', {})}\`; each row carries the ticket, constraints, commits, focus and open findings.`,
        `- Judge with \`${api('board-verdict', { landing: '<task#n>', verdict: 'approve|changes|hold', verified_commit: '<commit>', report: '<review report path>', rerun: { cmd: '<command>', result: '<result>' }, findings: [] })}\`. Give each finding a code, severity and a repro command: \`{"code":"M1","severity":"must|should|low","summary":"…","repro":"…"}\`.`,
        '- The review report path is yours to choose; a landing may suggest one (`review_report_path`), and `report` may then be left out.',
        '- Check `left_out` (rev-list commits the landing leaves out) before judging, and use the row\'s `next_verdict` as your report section\'s name.',
        '- approve is refused while the family has an open must finding: settle it with pm first, or answer `changes`.',
        '- To reopen a finding that was fixed, list it in the verdict\'s `"reopen"`.',
        '- A task assigned to you or that you landed commits for is not yours to judge; tell pm with `send-message` and leave it.',
        '- Do not send pm or the assignee a message about a verdict: the board notifies them.',
    ];
    if (workerRole === 'orchestrator' || workerRole === null) {
        lines.push(
            '',
            'As pm:',
            `- Put work on the board, not in a message: \`${api('board-add', { id: '<T…>', title: '<title>', assignee: '<worker>', reviewer: '<worker>', ticket: '<ticket path>', constraints: '<limits or 없음>', base: '<commit>' })}\`. Give ticket, constraints, base and reviewer; write 없음 when a task has no constraints (a missing or blank one leaves its review request incomplete).`,
            '- Assignee and reviewer are never the same worker; if you assign yourself a task, name a reviewer, or it cannot be landed.',
            '- Do not relay review requests or fix requests by message: a land notifies the reviewer (you, on a task without one), and every verdict notifies you and the assignee.',
            `- Record user decisions with \`${api('board-announce', { body: '<decision>' })}\`.`,
            '- Settle findings with `board-finding` (backlog, accepted-limit, rejected); reopening one needs an unfinished task in its family.',
            `- After a context compaction, recover from \`${api('board-status', {})}\`.`,
        );
    }
    return lines.join('\n');
}

export function generateWorkerOverlay(params) {
    const { teamName, workerName, agentType, bootstrapInstructions } = params;
    const workerRole = params.workerRole ?? null;
    const instructionStateRoot = params.instructionStateRoot ?? DEFAULT_INSTRUCTION_STATE_ROOT;
    const teamRoster = Array.isArray(params.teamRoster) ? params.teamRoster : [];
    const orchestratorNames = teamRoster
        .filter((p) => p.teamRole === 'orchestrator')
        .map((p) => p.name);

    const heartbeatPath = buildTeamStateInstructionPath(teamName, instructionStateRoot, 'workers', workerName, 'heartbeat.json');
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
- **Heartbeat**: Update ${heartbeatPath} every few minutes:
  \`\`\`json
  {"pid":<pid>,"last_turn_at":"<ISO timestamp>","turn_count":<n>,"alive":true}
  \`\`\`

${workerRole ? `${roleGuidance(workerRole, orchestratorNames)}

` : ''}${params.board ? `${boardGuidance(teamName, workerName, workerRole)}

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
  This creates \`<repo-root>/.worktrees/<new-name>\` on \`<branch>\` (new or existing), boots a peer there, and every worker sees it in the \`roster\` on its next \`mailbox-list\`. The peer inherits your launch flags. Then hand it a ticket via send-message. The worktree gives it its own working tree, so neither of you has to ask the other before editing a file — git resolves the rest at merge time. Worktree cleanup after merge is the user's job, not yours.
  \`--worktree\` is not optional here: add-worker REFUSES a \`--cwd\` that an existing worker already uses, because two workers in one working tree overwrite each other with no merge conflict to catch it. If you hit that error, add \`--worktree <branch>\` rather than reaching for the \`--allow-shared-cwd\` escape hatch — that flag is for the user to decide, not you.
  Spawn protocol (you keep the task context; the peer works alone and does not report as it goes):
  - \`--extra-prompt\` MUST say: "Spawned by ${workerName}. Message ${workerName} ONLY (a) when you need a decision to proceed — one message with expects_reply — or (b) when the ticket is done — one final report (reply_to the ticket). No progress updates, no acknowledgements: progress goes to your status file and your pane's stdout."${orchestratorNames.length > 0 ? `\n  - Tell the orchestrator (${orchestratorNames.join(', ')}) in ONE message that you spawned this peer and what it owns, so the team's picture of who is working stays complete.` : ''}
  - The ticket = goal + inputs (file paths) + expected deliverable + "reply to this message when done". Send it with expects_reply so the final report lands in your \`sent_pending\`.
  - Do not ask the peer for progress; read its status file or \`my-team status\` instead. Handle its report/question when it arrives in your inbox.
- **Retiring a peer you spawned**: when a peer you added has finished its part and its work is merged, remove it so the team stops waiting on it:
  \`my-team remove-worker --team ${teamName} --name <that-peer>\`
  This takes it off the roster, closes its pane, and tells the remaining workers to stop expecting replies from it. Only remove a peer whose work is done — never one that is mid-task, and never yourself. Its mailbox/archive and any worktree dir stay on disk for the user.
- **Succession (when the user tells you to hand over, e.g. "교대해")**: follow the "Worker succession" section of the \`my-team\` skill (\`/workflow:my-team\`). In short: write a handoff, then \`add-worker --name ${workerName}-2 --cwd "$PWD" --agent-type ${agentType} --extra-prompt "<handoff path + the user's focus instruction verbatim + 'ask ${workerName} everything, then remove-worker it'>"\`; from then on do nothing but answer the successor's questions — the successor retires you.
- **Closeout (when the user says your ticket is done, e.g. "마무리 보고해", "closeout")**: run the \`my-team-closeout\` skill (\`/workflow:my-team-closeout\`) — it sends an evidence-based final report to the worker that spawned you and lets THAT worker verify, then either \`remove-worker\` you (all done) or write a resume brief (unfinished; you stay). A message whose body starts with \`[closeout]\` in YOUR inbox means a peer you spawned is reporting in: follow the skill's receiver procedure. Never remove yourself.
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
