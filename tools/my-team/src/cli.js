/**
 * `my-team` CLI entry point.
 *
 * Subcommands (user-facing):
 *   start, status, shutdown, monitor, add-worker, remove-worker
 *
 * api subcommands (called by worker LLMs from AGENTS.md) — peer messaging only:
 *   api send-message, api mailbox-list, api mailbox-mark-delivered,
 *   api archive-lookup
 */

import { Command } from 'commander';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

import { runStart } from './commands/start.js';
import { runStatus } from './commands/status.js';
import { runShutdown } from './commands/shutdown.js';
import { runMonitor } from './commands/monitor.js';
import { runAddWorker } from './commands/add-worker.js';
import { runRemoveWorker } from './commands/remove-worker.js';

import { runApiSendMessage } from './commands/api/send-message.js';
import { runApiMailboxList } from './commands/api/mailbox-list.js';
import { runApiMailboxMarkDelivered } from './commands/api/mailbox-mark-delivered.js';
import { runApiArchiveLookup } from './commands/api/archive-lookup.js';
import { runApiRoster } from './commands/api/roster.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

function readVersion() {
    try {
        const pkg = JSON.parse(readFileSync(join(__dirname, '..', 'package.json'), 'utf-8'));
        return pkg.version;
    } catch {
        return '0.0.0';
    }
}

function parseApiInput(opts) {
    if (!opts.input) {
        throw new Error('--input <json> is required for api subcommands');
    }
    try {
        return JSON.parse(opts.input);
    } catch (err) {
        throw new Error(`--input is not valid JSON: ${err.message}`);
    }
}

function emit(result, jsonOutput) {
    if (jsonOutput) {
        console.log(JSON.stringify(result, null, 2));
    } else if (result !== undefined) {
        console.log(typeof result === 'string' ? result : JSON.stringify(result, null, 2));
    }
}

async function main() {
    const program = new Command();
    program
        .name('my-team')
        .description('Multi-project tmux worker orchestration with per-worker cwd.')
        .version(readVersion());

    // start
    program
        .command('start')
        .description('Boot a team from config or inline workers')
        .option('--config <path>', 'config file path (JSON)')
        .option('--name <name>', 'team name (for inline mode)')
        .option('--worker <spec>', 'inline worker: name:agent_type:cwd', (v, prev) => {
            prev = prev || [];
            prev.push(v);
            return prev;
        })
        .option('--new-window', 'create new tmux window instead of splitting current')
        .option('--detached', 'force detached tmux session')
        .option('--dry-run', 'show plan without spawning')
        .action(async (opts) => {
            await runStart(opts);
        });

    // status
    program
        .command('status')
        .description('Show team state, workers, tasks')
        .option('--team <name>', 'team name (required unless --all)')
        .option('--state-root <path>', 'override state root')
        .option('--json', 'JSON output')
        .option('--all', 'every team under the state base (requires --json)')
        .action(async (opts) => {
            await runStatus(opts);
        });

    // shutdown
    program
        .command('shutdown')
        .description('Terminate a team')
        .requiredOption('--team <name>', 'team name')
        .option('--state-root <path>', 'override state root')
        .action(async (opts) => {
            await runShutdown(opts);
        });

    // monitor
    program
        .command('monitor <team-name>')
        .description('Tail worker-to-worker message log in real-time (Ctrl+C to exit)')
        .option('--state-root <path>', 'override state root')
        .action(async (teamName, opts) => {
            await runMonitor(teamName, opts);
        });

    // add-worker
    program
        .command('add-worker')
        .description('Add one worker to a running team mid-session')
        .requiredOption('--team <name>', 'team name')
        .requiredOption('--name <name>', 'worker name')
        .requiredOption('--agent-type <type>', 'agent type (claude|codex|gemini|cursor)')
        .requiredOption('--cwd <path>', 'worker working directory')
        .option('--role <role>', "team role: orchestrator|worker. In a role-declaring team, omitting this defaults to 'worker'")
        .option('--description <text>', 'one-liner peers see in the roster (what to ask this worker for)')
        .option('--extra-prompt <text>', "the worker's own work brief (purpose, goal, first task); rendered into its AGENTS.md ## Role Context, same as config extra_prompt")
        .option('--worktree <branch>', 'create <repo>/.worktrees/<name> on this branch (from the git repo at --cwd) and boot the worker there — parallel work on one repo')
        .option('--allow-shared-cwd', 'permit --cwd that an existing worker already uses. Refused by default: two workers in one working tree overwrite each other silently (same branch, so git reports no conflict). Prefer --worktree.')
        .option('--launch-arg <arg>', 'extra CLI arg for the worker (repeatable; e.g. --launch-arg --dangerously-skip-permissions). Without a permission-bypass flag the worker runs supervised and stalls on its first permission prompt until you answer it in its pane.', (v, prev) => {
            prev = prev || [];
            prev.push(v);
            return prev;
        })
        .option('--state-root <path>', 'override state root')
        .action(async (opts) => {
            // commander stores repeated --launch-arg under opts.launchArg; add-worker reads opts.launchArgs
            await runAddWorker({ ...opts, launchArgs: opts.launchArg });
        });

    // remove-worker
    program
        .command('remove-worker')
        .description('Remove one worker from a running team mid-session (inverse of add-worker)')
        .requiredOption('--team <name>', 'team name')
        .requiredOption('--name <name>', 'worker name')
        .option('--state-root <path>', 'override state root')
        .action(async (opts) => {
            await runRemoveWorker(opts);
        });

    // api ... (peer messaging only)
    const api = program.command('api').description('Internal API used by worker LLMs for peer messaging');

    api.command('send-message')
        .description('[mutating] Send a peer message — drops a spool file, appends sender archive, records sent_pending. Add "to_team":"<team name>" to reach a worker in another running team.')
        .requiredOption('--input <json>', 'JSON payload')
        .option('--json', 'JSON output')
        .action(async (opts) => emit(await runApiSendMessage(parseApiInput(opts)), opts.json));

    api.command('mailbox-list')
        .description('[mutating] List unread inbox — absorbs the incoming-spool into the mailbox first (this absorption is the polling side effect: skip the poll and new messages are never absorbed)')
        .requiredOption('--input <json>', 'JSON payload')
        .option('--json', 'JSON output')
        .action(async (opts) => emit(await runApiMailboxList(parseApiInput(opts)), opts.json));

    api.command('mailbox-mark-delivered')
        .description('[mutating] Mark an inbox entry consumed — moves it to the archive jsonl and removes it from the inbox')
        .requiredOption('--input <json>', 'JSON payload')
        .option('--json', 'JSON output')
        .action((opts) => emit(runApiMailboxMarkDelivered(parseApiInput(opts)), opts.json));

    api.command('archive-lookup')
        .description('[pure] Look up an archived message by id — read-only, no side effects')
        .requiredOption('--input <json>', 'JSON payload')
        .option('--json', 'JSON output')
        .action((opts) => emit(runApiArchiveLookup(parseApiInput(opts)), opts.json));

    api.command('roster')
        .description('[pure] Current workers of a team (name, agent_type, role, description) — the registry other teams address by team name')
        .requiredOption('--input <json>', 'JSON payload: {"team_name":"<team>"}')
        .option('--json', 'JSON output')
        .action(async (opts) => emit(await runApiRoster(parseApiInput(opts)), opts.json));

    try {
        await program.parseAsync(process.argv);
    } catch (err) {
        console.error(`[my-team] error: ${err.message}`);
        process.exit(1);
    }
}

main();
