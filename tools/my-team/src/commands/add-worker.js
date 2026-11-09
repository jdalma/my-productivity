/**
 * `my-team add-worker` — add ONE worker to an ALREADY-RUNNING team mid-session.
 *
 * Counterpart to `start` (AC-28 rejects a second `start` on a live team; this
 * command REQUIRES the team be live). The single sufficient condition for the
 * new worker to send/receive peer messages is its presence in
 * `manifest.workers` — `send-message` enforces roster membership per call
 * (send-message.js:58,65). So the manifest append is the transaction commit
 * point; everything before it is reversible by killing the new pane, and
 * nothing after it can fail destructively.
 *
 * Existing workers learn about the new peer via an in-pane notice (the only
 * runtime-awareness channel — a running worker CLI has already loaded its
 * AGENTS.md, so rewriting it on disk would not reach the live LLM). Per the
 * confirmed design decision we do NOT rewrite existing workers' AGENTS.md.
 *
 * The tmux-touching functions are injected via `deps` so the validation /
 * manifest / rollback logic is unit-testable without a real tmux session.
 */

import { join, basename, dirname, resolve } from 'path';
import { appendFile, mkdir, readFile, writeFile } from 'fs/promises';
import { execFileSync } from 'child_process';
import { homedir } from 'os';

import { loadManifest, manifestPathForTeam, resolveTeamManifest } from './_manifest.js';
import { WORKER_NAME_PATTERN, validateWorker } from '../config/parser.js';
import { AGENT_CLI, stripSessionArgs, validateAgentCLIs } from './start.js';
import { sanitizeName } from '../lib/team-name.js';
import { ensureWorkerStateDir, generateWorkerOverlay } from '../lib/worker-bootstrap.js';
import { atomicWriteJson } from '../lib/fs-utils.js';
import {
    isWorkerAlive, addWorkerPane, applyTeamLayout, sendToWorker,
    spawnWorkerInPane, waitForPaneReady,
} from '../lib/tmux-session.js';
import { tmuxExecAsync } from '../lib/tmux-utils.js';

const MAX_WORKERS = 10;

function git(cwd, args) {
    return execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

/**
 * Canonical form for comparing two `cwd` values. The manifest stores absolute,
 * tilde-expanded paths (validateWorker does the expansion), but `--cwd` may
 * arrive as `~/foo`, a relative path, or with a trailing slash. Compare only
 * after putting both through this.
 *
 * Deliberately no realpath(): it touches the filesystem and would throw for a
 * path that does not exist yet — this guard must stay side-effect free. A
 * symlinked duplicate therefore slips through, which is the accepted limit.
 */
function normalizeCwd(cwd) {
    if (typeof cwd !== 'string' || cwd === '') return '';
    const expanded = cwd === '~' || cwd.startsWith('~/')
        ? join(homedir(), cwd.slice(1))
        : cwd;
    return resolve(expanded);
}

/**
 * Create `<repo-root>/.worktrees/<name>` on `branch` (created if missing).
 * The dir is added to .git/info/exclude (local, untracked) so the main
 * checkout's `git status` stays clean. Returns { path, remove } where remove()
 * undoes the creation — used as rollback when a later step fails. Cleanup after
 * the work is merged is deliberately the user's job.
 */
async function createWorktree(repoCwd, name, branch) {
    let root;
    try {
        root = git(repoCwd, ['rev-parse', '--show-toplevel']);
    } catch {
        throw new Error(`--worktree requires --cwd inside a git repository; ${repoCwd} is not a git repository.`);
    }
    const path = join(root, '.worktrees', name);
    let branchExists = true;
    try { git(root, ['rev-parse', '--verify', '--quiet', `refs/heads/${branch}`]); } catch { branchExists = false; }
    git(root, branchExists ? ['worktree', 'add', path, branch] : ['worktree', 'add', '-b', branch, path]);
    const exclude = resolve(root, git(root, ['rev-parse', '--git-common-dir']), 'info', 'exclude');
    await mkdir(dirname(exclude), { recursive: true });
    const current = await readFile(exclude, 'utf-8').catch(() => '');
    if (!/^\.worktrees\/$/m.test(current)) await appendFile(exclude, `${current.endsWith('\n') || !current ? '' : '\n'}.worktrees/\n`);
    return { path, remove: () => git(root, ['worktree', 'remove', '--force', path]) };
}

export async function runAddWorker(opts, deps = {}) {
    const {
        isWorkerAlive: _isWorkerAlive = isWorkerAlive,
        addWorkerPane: _addWorkerPane = addWorkerPane,
        spawnWorkerInPane: _spawnWorkerInPane = spawnWorkerInPane,
        waitForPaneReady: _waitForPaneReady = waitForPaneReady,
        sendToWorker: _sendToWorker = sendToWorker,
        killPane: _killPane = (id) => tmuxExecAsync(['kill-pane', '-t', id]),
    } = deps;

    // ── Step 1: validation gates (no side effects; throw on failure) ──
    if (!opts.team) throw new Error('--team is required');
    if (!opts.name) throw new Error('--name is required');
    if (!opts.cwd) throw new Error('--cwd is required');
    if (!opts.agentType) throw new Error('--agent-type is required');

    // Commander camelCases --agent-type → opts.agentType; the validators read
    // snake_case w.agent_type, so map explicitly (a bare opts.agent_type would
    // be undefined and slip through to a crash at spawn).
    const newWorker = { name: opts.name, cwd: opts.cwd, agent_type: opts.agentType };
    if (opts.role !== undefined) newWorker.role = opts.role;
    if (opts.description !== undefined) newWorker.description = opts.description;

    // Resolve --team as EITHER a team name OR a tmux session name (what
    // `tmux ls` shows). resolveTeamManifest scans manifests by session_name
    // when the value is not a team dir. CRITICAL: adopt the canonical team
    // name it returns — every downstream step (overlay teamName, MY_TEAM_WORKER
    // env, greeting, and the Step 7 reload via opts.team) must key off the real
    // team name, not the session-name input. Without this, a session-name input
    // would split a pane and then fail the commit-point reload (dir not found),
    // rolling back and killing the just-spawned pane.
    const { manifest, teamName } = resolveTeamManifest(opts.team, opts.stateRoot);
    opts.team = teamName;

    // Liveness: the team must actually be live. Anchor the new pane on the
    // first ALIVE worker pane — not blindly workers[0], which may have crashed
    // while the rest of the team is fine (a dead anchor would make the later
    // split-window fail). The host/leader pane is excluded: in split-pane mode
    // it is the user's own pane and always reads alive, which would not prove
    // the team is up. _isWorkerAlive is async, so iterate explicitly — a
    // `.find(async …)` would treat every Promise as truthy and skip the check.
    let anchor = null;
    for (const w of manifest.workers) {
        if (await _isWorkerAlive(w.pane_id)) { anchor = w; break; }
    }
    if (!anchor) {
        throw new Error(`Team '${opts.team}' session is not live (no alive worker pane). Is the team running?`);
    }

    if (manifest.workers.length + 1 > MAX_WORKERS) {
        throw new Error(`workers cannot exceed ${MAX_WORKERS}. Team already has ${manifest.workers.length}.`);
    }

    if (!WORKER_NAME_PATTERN.test(opts.name)) {
        throw new Error(`--name must match ${WORKER_NAME_PATTERN}. Got: ${JSON.stringify(opts.name)}`);
    }
    if (manifest.workers.some((w) => w.name === opts.name)) {
        throw new Error(`Duplicate worker name '${opts.name}' — already in team '${opts.team}'.`);
    }
    const sn = sanitizeName(opts.name);
    if (manifest.workers.some((w) => sanitizeName(w.name) === sn)) {
        throw new Error(`Worker name '${opts.name}' collides with an existing worker after sanitization ('${sn}').`);
    }

    // Shared-cwd guard. Two workers in ONE working tree is the single case git
    // cannot rescue: same branch, same files, so there is no merge conflict to
    // resolve — one worker's edit silently overwrites the other's. (Separate
    // worktrees are fine: different dirs, different branches, conflicts surface
    // at merge.) my-team deliberately does not track file ownership, so this
    // guard is what makes that omission safe. Refuse before ANY side effect —
    // this runs before createWorktree and before the pane split.
    if (!opts.worktree && !opts.allowSharedCwd) {
        const target = normalizeCwd(opts.cwd);
        const sharing = manifest.workers.filter((w) => normalizeCwd(w.cwd) === target);
        if (sharing.length > 0) {
            throw new Error(
                `--cwd ${opts.cwd} is already used by ${sharing.map((w) => `'${w.name}'`).join(', ')}. `
                + 'Two workers in one working tree overwrite each other silently (same branch, so git '
                + 'never reports a conflict). Use --worktree <branch> to give this worker its own '
                + 'working tree, or pass --allow-shared-cwd if they will not edit the same files.'
            );
        }
    }

    // Field-level validation (cwd exists+dir, agent_type whitelist, etc.).
    // seed `seen` with existing names so a dup is caught here too. validateWorker
    // returns a normalized worker whose `cwd` is tilde-EXPANDED — use that from
    // here on, so `~/foo` reaches tmux split-window and the manifest as the
    // absolute path (matching what start.js stores), never the literal "~/foo".
    let worktree = null;
    if (opts.worktree) {
        worktree = await createWorktree(opts.cwd, opts.name, opts.worktree);
        newWorker.cwd = worktree.path;
        if (!newWorker.description) newWorker.description = `worktree ${opts.worktree} of ${basename(git(worktree.path, ['rev-parse', '--show-toplevel']).replace(/\/\.worktrees\/[^/]+$/, ''))}`;
    }
    try {
        return await addValidatedWorker(opts, deps, manifest, anchor, newWorker);
    } catch (err) {
        if (worktree) { try { worktree.remove(); } catch { /* best effort */ } }
        throw err;
    }
}

async function addValidatedWorker(opts, deps, manifest, anchor, newWorker) {
    const {
        addWorkerPane: _addWorkerPane = addWorkerPane,
        spawnWorkerInPane: _spawnWorkerInPane = spawnWorkerInPane,
        waitForPaneReady: _waitForPaneReady = waitForPaneReady,
        sendToWorker: _sendToWorker = sendToWorker,
        killPane: _killPane = (id) => tmuxExecAsync(['kill-pane', '-t', id]),
    } = deps;
    const validated = validateWorker(
        newWorker, manifest.workers.length, new Set(manifest.workers.map((w) => w.name))
    );
    const cwd = validated.cwd;

    // Role: in a role-declaring team, an added worker without --role defaults
    // to 'worker' (same rule as validateConfig). In a legacy peer team it
    // stays null so no guard activates.
    const teamUsesRoles = manifest.workers.some((w) => w.role === 'orchestrator' || w.role === 'worker');
    const workerRole = validated.role ?? (teamUsesRoles ? 'worker' : null);

    // Agent CLI on PATH. validateAgentCLIs iterates config.workers, so wrap.
    validateAgentCLIs({ workers: [newWorker] });

    // Launch flags: explicit --launch-arg wins; otherwise a worker-initiated
    // add inherits the caller's flags (MY_TEAM_WORKER=<team>/<name>), so a peer
    // spawned from a bypass-permissions worker does not stall on prompts.
    let launchArgs = Array.isArray(opts.launchArgs) ? opts.launchArgs : [];
    const callerName = process.env.MY_TEAM_WORKER?.startsWith(`${opts.team}/`) ? process.env.MY_TEAM_WORKER.slice(opts.team.length + 1) : null;
    const caller = callerName ? manifest.workers.find((w) => w.name === callerName) : null;
    if (launchArgs.length === 0 && Array.isArray(caller?.launch_args)) launchArgs = stripSessionArgs(caller.launch_args, caller.agent_type);

    // ── Step 2: state dir + new worker AGENTS.md (idempotent; no pane yet) ──
    const stateRoot = manifest.state_root;
    await ensureWorkerStateDir(opts.team, opts.name, stateRoot);

    // New roster = existing workers + the newcomer. Descriptions come from the
    // manifest (start persists them), so the newcomer sees real peer roles.
    const description = (validated.description ?? '').split('\n')[0].trim(); // one line, same as start
    const teamRoster = [
        ...manifest.workers.map((w) => ({ name: w.name, agentType: w.agent_type, role: w.description ?? '', teamRole: w.role ?? null })),
        { name: opts.name, agentType: opts.agentType, role: description, teamRole: workerRole },
    ];
    const overlay = generateWorkerOverlay({
        teamName: opts.team,
        workerName: opts.name,
        agentType: opts.agentType,
        workerRole,
        bootstrapInstructions: opts.extraPrompt ?? '',
        instructionStateRoot: stateRoot,
        cwd,
        teamRoster,
    });
    const overlayPath = join(stateRoot, 'workers', opts.name, 'AGENTS.md');
    await writeFile(overlayPath, overlay, 'utf-8');

    // ── Step 3: split a new pane (every failure past here kills this pane) ──
    const { paneId } = await _addWorkerPane(
        manifest.session_name, anchor.pane_id, { name: opts.name, cwd }
    );

    try {
        // ── Step 4: spawn the worker CLI (full envVars block, like start) ──
        const startConfig = {
            teamName: opts.team,
            workerName: opts.name,
            launchBinary: AGENT_CLI[opts.agentType].bin,
            launchArgs,
            envVars: {
                MY_TEAM_WORKER: `${opts.team}/${opts.name}`,
                MY_TEAM_STATE_ROOT: stateRoot,
                OMC_TEAM_WORKER: `${opts.team}/${opts.name}`,
            },
        };
        const launched = await _spawnWorkerInPane(manifest.session_name, paneId, startConfig);
        if (launched === false) {
            console.warn(`[my-team] '${opts.name}' pane ${paneId} created but CLI NOT launched (see warning above)`);
        }

        // ── Step 5: wait for the pane to be ready ──
        // Best-effort, matching start.js:238 — waitForPaneReady returns false on
        // timeout (it does not throw), and we deliberately ignore that: we still
        // commit the worker even if its CLI didn't signal ready within 30s, just
        // as `start` does for its initial workers. The worker may simply be slow.
        await _waitForPaneReady(paneId, { timeoutMs: 30000 });

        // ── Step 6: re-assert label + re-tile (cosmetic; ignore failures) ──
        try { await tmuxExecAsync(['set-option', '-p', '-t', paneId, '@worker_name', opts.name]); } catch { /* ignore */ }
        try { await applyTeamLayout(manifest.session_name); } catch { /* ignore */ }

        // ── Step 7: manifest reload + append (commit point) ──
        // Reload so we don't clobber a concurrent change and so we abort if the
        // team was shut down mid-operation (manifest gone → loadManifest throws).
        let fresh;
        try {
            fresh = loadManifest(opts.team, opts.stateRoot);
        } catch {
            throw new Error('team was shut down mid-operation (manifest gone)');
        }
        fresh.workers.push({
            name: opts.name,
            pane_id: paneId,
            cwd,
            agent_type: opts.agentType,
            role: workerRole,
            description,
            launch_args: stripSessionArgs(launchArgs, opts.agentType),
            overlay_path: overlayPath,
        });
        atomicWriteJson(manifestPathForTeam(opts.team, opts.stateRoot), fresh);
    } catch (err) {
        // Rollback: discard the orphan pane, leave the manifest untouched.
        try { await _killPane(paneId); } catch { /* best effort */ }
        throw err;
    }

    // ── Step 8: join notice (the new worker reports in) ──
    // Awareness of a new peer is ALREADY solved by `mailbox-list`'s `roster`
    // field, which every worker polls each cycle — so a greeting to every peer
    // is a duplicate channel that costs 2N messages per join (N greetings, N
    // expects_reply acks).
    //
    // So: in a role-declaring team the newcomer reports ONLY to the
    // orchestrator(s), one message, no expects_reply, so the orchestrator can
    // tell the user who joined and why. File overlap is deliberately NOT part
    // of that report — parallel work on one repo runs on separate git
    // worktrees, so workers do not share a working tree and git resolves the
    // rest at merge time. In a legacy peer team there is no orchestrator, so
    // the newcomer stays silent and peers learn of it through the roster.
    //
    // The notice embeds the ABSOLUTE overlayPath (same as start.js:259), not a
    // bare "your AGENTS.md": the worker CLI boots in its own cwd and nothing
    // wires the overlay (which lives under state_root, far from cwd) into it, so
    // without the explicit path the worker cannot find its roster and falls back
    // to an unrelated team source. overlayPath is built from runtime values
    // (state_root + worker name) — no session/team name is hardcoded.
    const orchestrators = manifest.workers
        .filter((w) => w.role === 'orchestrator')
        .map((w) => w.name);
    const reportIn = orchestrators.length > 0
        ? ` Then send ONE message (no expects_reply) to ${orchestrators.join(', ')} `
          + 'stating your name, your cwd, and your assignment in one line. '
          + 'Do not message any other worker.'
        : ' Do not introduce yourself to peers — they see you in the `roster` '
          + 'field of their next mailbox-list.';
    const greeting =
        `You just joined team '${opts.team}'. First action: read ${overlayPath} `
        + `for the roster + peer protocol.${reportIn}`;
    try {
        const sent = await _sendToWorker(manifest.session_name, paneId, greeting);
        if (sent === false) {
            // sendToWorker rejects (returns false) past its char cap or on a
            // busy/copy-mode pane. Surface it: a silently-dropped greeting means
            // the worker never learns its roster path — the exact failure this
            // command exists to prevent.
            console.warn(
                `[my-team] join greeting was NOT delivered to '${opts.name}' (pane ${paneId}). `
                + `The worker may not know its AGENTS.md path — point it to ${overlayPath} manually.`
            );
        }
    } catch { /* warn-only */ }

    console.log(`[my-team] Added worker '${opts.name}' to team '${opts.team}' (pane ${paneId}, cwd: ${cwd}, cli: ${AGENT_CLI[opts.agentType].bin}).`);
    return { name: opts.name, pane_id: paneId, overlay_path: overlayPath };
}
