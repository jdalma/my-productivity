/**
 * Adapted from oh-my-claude-sisyphus (MIT License)
 * https://github.com/Yeachan-Heo/oh-my-claudecode
 *
 * Source: dist/team/tmux-session.js
 * Modifications:
 *  - `createTeamSession(teamName, workers, cwd, options)` takes a `workers`
 *    array (each with `name` and `cwd`) instead of a single `workerCount`.
 *    Each worker pane is spawned with `tmux split-window -c <worker.cwd>`.
 *    This is the core change that lifts OMC's single-cwd constraint.
 *  - `sanitizeName` moved to `./team-name.js` (re-exported here for back-compat).
 *  - Pruned OMC-internal helpers we don't need (worktree assertions, etc.).
 */

import { existsSync } from 'fs';
import { join, basename, isAbsolute, win32 } from 'path';

import { validateTeamName, sanitizeName } from './team-name.js';
import { tmuxExec, tmuxExecAsync, tmuxShell, tmuxCmdAsync } from './tmux-utils.js';

export { sanitizeName };

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const TMUX_SESSION_PREFIX = 'my-team';

export function detectTeamMultiplexerContext(env = process.env) {
    if (env.TMUX) return 'tmux';
    if (env.CMUX_SURFACE_ID) return 'cmux';
    return 'none';
}

export function isUnixLikeOnWindows() {
    return process.platform === 'win32' && !!(process.env.MSYSTEM || process.env.MINGW_PREFIX);
}

/**
 * Apply a grid (tiled) layout to the team window. tmux auto-arranges panes
 * into roughly equal rows × cols (e.g. 4 panes → 2x2, 6 → 2x3 or 3x2).
 *
 * Also enables pane-border-status so each pane's title (set via
 * `select-pane -T <name>`) is shown on the top border line.
 */
export async function applyTeamLayout(teamTarget) {
    try {
        await tmuxExecAsync(['select-layout', '-t', teamTarget, 'tiled']);
    } catch { /* ignore */ }
    // Show pane titles on the top border of every pane in this window.
    try {
        await tmuxExecAsync(['set-window-option', '-t', teamTarget, 'pane-border-status', 'top']);
    } catch { /* ignore */ }
    // Render @worker_name (set per pane) when present, otherwise fall back to
    // pane_title (used for the host pane). Worker CLIs continuously emit OSC
    // title sequences that overwrite pane_title — `allow-rename off` only
    // protects window names, not pane titles, so we route worker labels
    // through a pane-scoped user option that the CLI cannot touch.
    try {
        await tmuxExecAsync([
            'set-window-option', '-t', teamTarget,
            'pane-border-format', ' #{?@worker_name,#{@worker_name},#{pane_title}} ',
        ]);
    } catch { /* ignore */ }
    // allow-rename / automatic-rename still useful to keep window name stable.
    try {
        await tmuxExecAsync(['set-window-option', '-t', teamTarget, 'allow-rename', 'off']);
    } catch { /* ignore */ }
    try {
        await tmuxExecAsync(['set-window-option', '-t', teamTarget, 'automatic-rename', 'off']);
    } catch { /* ignore */ }
}

const SUPPORTED_POSIX_SHELLS = new Set(['sh', 'bash', 'zsh', 'fish', 'ksh']);
export function getDefaultShell() {
    if (process.platform === 'win32' && !isUnixLikeOnWindows()) {
        return process.env.COMSPEC || 'cmd.exe';
    }
    const shell = process.env.SHELL || '/bin/bash';
    const name = basename(shell.replace(/\\/g, '/')).replace(/\.(exe|cmd|bat)$/i, '');
    if (!SUPPORTED_POSIX_SHELLS.has(name)) return '/bin/sh';
    return shell;
}

function shellEscape(value) {
    return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function assertSafeEnvKey(key) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
        throw new Error(`Invalid environment key: "${key}"`);
    }
}

const DANGEROUS_LAUNCH_BINARY_CHARS = /[;&|`$()<>\n\r\t\0]/;
function isAbsoluteLaunchBinaryPath(value) {
    return isAbsolute(value) || win32.isAbsolute(value);
}

function assertSafeLaunchBinary(launchBinary) {
    if (launchBinary.trim().length === 0) {
        throw new Error('Invalid launchBinary: value cannot be empty');
    }
    if (launchBinary !== launchBinary.trim()) {
        throw new Error('Invalid launchBinary: value cannot have leading/trailing whitespace');
    }
    if (DANGEROUS_LAUNCH_BINARY_CHARS.test(launchBinary)) {
        throw new Error('Invalid launchBinary: contains dangerous shell metacharacters');
    }
    if (/\s/.test(launchBinary) && !isAbsoluteLaunchBinaryPath(launchBinary)) {
        throw new Error('Invalid launchBinary: paths with spaces must be absolute');
    }
}

/**
 * Build a safe shell command for spawning a worker CLI in a tmux pane.
 * env vars are escaped, login shell sources rc file, then `exec` worker.
 */
export function buildWorkerStartCommand(config) {
    const shell = getDefaultShell();
    const shouldSourceRc = process.env.MY_TEAM_NO_RC !== '1' && process.env.OMC_TEAM_NO_RC !== '1';

    if (!config.launchBinary) {
        throw new Error('Missing worker launch command. Provide launchBinary.');
    }
    assertSafeLaunchBinary(config.launchBinary);
    const launchWords = [config.launchBinary, ...(config.launchArgs ?? [])];

    const envAssignments = Object.entries(config.envVars ?? {}).map(([key, value]) => {
        assertSafeEnvKey(key);
        return `${key}=${shellEscape(value)}`;
    });

    const shellName = basename(shell.replace(/\\/g, '/')).replace(/\.(exe|cmd|bat)$/i, '');
    const isFish = shellName === 'fish';
    const execArgsCommand = isFish ? 'exec $argv' : 'exec "$@"';

    let rcFile = '';
    if (process.env.HOME) {
        rcFile = isFish
            ? `${process.env.HOME}/.config/fish/config.fish`
            : `${process.env.HOME}/.${shellName}rc`;
    }

    let script;
    if (isFish) {
        script = shouldSourceRc && rcFile
            ? `test -f ${shellEscape(rcFile)}; and source ${shellEscape(rcFile)}; ${execArgsCommand}`
            : execArgsCommand;
    } else {
        script = shouldSourceRc && rcFile
            ? `[ -f ${shellEscape(rcFile)} ] && . ${shellEscape(rcFile)}; ${execArgsCommand}`
            : execArgsCommand;
    }
    const shellFlags = isFish ? ['-l', '-c'] : ['-lc'];

    return [
        shellEscape('env'),
        ...envAssignments,
        ...[shell, ...shellFlags, script, '--', ...launchWords].map(shellEscape),
    ].join(' ');
}

export function validateTmux(hasTmuxContext = false) {
    if (hasTmuxContext) return;
    try {
        tmuxShell('-V', { stripTmux: true, timeout: 5000, stdio: 'pipe' });
    } catch {
        throw new Error(
            'tmux is not available. Install it:\n' +
            '  macOS: brew install tmux\n' +
            '  Ubuntu/Debian: sudo apt-get install tmux\n' +
            '  Fedora: sudo dnf install tmux'
        );
    }
}

export function sessionName(teamName, workerName) {
    return `${TMUX_SESSION_PREFIX}-${sanitizeName(teamName)}-${sanitizeName(workerName)}`;
}

/**
 * Create a tmux topology of a host pane + N worker panes.
 *
 * The host pane (kept in `leaderPaneId` for OMC manifest compatibility) is
 * NOT an orchestrator role — my-team is peer-to-peer. It is just the first
 * pane in the layout: either the user's own pane (in-place mode) or the
 * empty shell that runs `my-team monitor` (detached mode). No worker reports
 * to it and no code routes worker traffic through it.
 *
 * SIGNATURE CHANGE from OMC: instead of `(teamName, workerCount, cwd)` we take
 * `(teamName, workers, options)` where `workers: [{name, cwd}]`. Each worker
 * pane is launched at its own `cwd`, lifting OMC's single-cwd constraint.
 *
 * Returns { sessionName, leaderPaneId, workerPanes: [{name, paneId}], sessionMode }.
 */
export async function createTeamSession(teamName, workers, options = {}) {
    validateTeamName(teamName);
    const multiplexerContext = detectTeamMultiplexerContext();
    const inTmux = multiplexerContext === 'tmux';
    const useDedicatedWindow = Boolean(options.newWindow && inTmux);

    if (!inTmux) {
        validateTmux();
    }

    const envPaneIdRaw = (process.env.TMUX_PANE ?? '').trim();
    const envPaneId = /^%\d+$/.test(envPaneIdRaw) ? envPaneIdRaw : '';
    let sessionAndWindow = '';
    let leaderPaneId = envPaneId;
    let sessionMode = inTmux ? 'split-pane' : 'detached-session';

    // Detached fallback: create a new tmux session, leader cwd defaults to first worker's cwd or HOME.
    if (!inTmux) {
        const leaderCwd = options.leaderCwd || workers[0]?.cwd || process.env.HOME || '/';
        const detachedSessionName = `${TMUX_SESSION_PREFIX}-${sanitizeName(teamName)}-${Date.now().toString(36)}`;
        const detachedResult = await tmuxExecAsync([
            'new-session', '-d', '-P', '-F', '#S:0 #{pane_id}',
            '-s', detachedSessionName,
            '-c', leaderCwd,
        ], { stripTmux: true });
        const detachedLine = detachedResult.stdout.trim();
        const detachedMatch = detachedLine.match(/^(\S+)\s+(%\d+)$/);
        if (!detachedMatch) {
            throw new Error(`Failed to create detached tmux session: "${detachedLine}"`);
        }
        sessionAndWindow = detachedMatch[1];
        leaderPaneId = detachedMatch[2];
    }

    if (inTmux && envPaneId) {
        try {
            const targetedContextResult = await tmuxExecAsync([
                'display-message', '-p', '-t', envPaneId, '#S:#I',
            ]);
            sessionAndWindow = targetedContextResult.stdout.trim();
        } catch {
            sessionAndWindow = '';
            leaderPaneId = '';
        }
    }

    if (!sessionAndWindow || !leaderPaneId) {
        const contextResult = await tmuxCmdAsync(['display-message', '-p', '#S:#I #{pane_id}']);
        const contextLine = contextResult.stdout.trim();
        const contextMatch = contextLine.match(/^(\S+)\s+(%\d+)$/);
        if (!contextMatch) {
            throw new Error(`Failed to resolve tmux context: "${contextLine}"`);
        }
        sessionAndWindow = contextMatch[1];
        leaderPaneId = contextMatch[2];
    }

    if (useDedicatedWindow) {
        const targetSession = sessionAndWindow.split(':')[0] ?? sessionAndWindow;
        const windowName = `mt-${sanitizeName(teamName)}`.slice(0, 32);
        const newWindowResult = await tmuxExecAsync([
            'new-window', '-d', '-P', '-F', '#S:#I #{pane_id}',
            '-t', targetSession,
            '-n', windowName,
            '-c', workers[0]?.cwd || process.env.HOME || '/',
        ]);
        const newWindowLine = newWindowResult.stdout.trim();
        const newWindowMatch = newWindowLine.match(/^(\S+)\s+(%\d+)$/);
        if (!newWindowMatch) {
            throw new Error(`Failed to create team tmux window: "${newWindowLine}"`);
        }
        sessionAndWindow = newWindowMatch[1];
        leaderPaneId = newWindowMatch[2];
        sessionMode = 'dedicated-window';
    }

    const teamTarget = sessionAndWindow;
    const resolvedSessionName = teamTarget.split(':')[0];
    const workerPanes = [];

    if (!workers || workers.length === 0) {
        return { sessionName: teamTarget, leaderPaneId, workerPanes, sessionMode };
    }

    // === CORE CHANGE: per-worker cwd ===
    // Split direction alternates h/v so tiled layout has something to work with.
    // CRITICAL: re-tile after EVERY split, not just once at the end. A chain
    // split (each pane carved out of the previous one) halves the same lineage
    // each step — 24 rows → 12 → 6 → 3 → "no space for new pane" around the 7th
    // pane, even though the window has ample room for the final grid. Re-tiling
    // after each split lands the next split on a healthy grid cell instead of a
    // degenerate sliver, so e.g. 8 workers + host (9 panes) fit even at 80x24.
    for (let i = 0; i < workers.length; i++) {
        const w = workers[i];
        if (!w?.cwd) throw new Error(`Worker '${w?.name}' missing cwd`);
        const splitTarget = i === 0 ? leaderPaneId : workerPanes[i - 1].paneId;
        const splitType = i % 2 === 0 ? '-h' : '-v';
        const splitResult = await tmuxCmdAsync([
            'split-window', splitType, '-t', splitTarget,
            '-d', '-P', '-F', '#{pane_id}',
            '-c', w.cwd,                              // ← PER-WORKER CWD (the whole point)
        ]);
        const paneId = splitResult.stdout.split('\n')[0]?.trim();
        if (paneId) {
            workerPanes.push({ name: w.name, paneId });
            // Re-tile immediately so the next split has a full-size cell to halve.
            try {
                await tmuxExecAsync(['select-layout', '-t', teamTarget, 'tiled']);
            } catch { /* ignore — applyTeamLayout below re-tiles as well */ }
            // Store worker name in a pane-scoped user option. pane-border-format
            // reads @worker_name, which the worker CLI cannot overwrite via OSC.
            try {
                await tmuxExecAsync(['set-option', '-p', '-t', paneId, '@worker_name', w.name]);
            } catch { /* ignore — title is cosmetic */ }
        }
    }

    // Also label the host pane so it's not blank in the grid. The tmux title
    // string is kept as "leader" for visual compatibility with existing
    // screenshots/docs; the role itself is just "user's host pane" (not an
    // orchestrator). See createTeamSession docstring.
    try {
        await tmuxExecAsync(['select-pane', '-t', leaderPaneId, '-T', 'leader']);
    } catch { /* ignore */ }

    await applyTeamLayout(teamTarget);
    try { await tmuxExecAsync(['set-option', '-t', resolvedSessionName, 'mouse', 'on']); } catch { /* ignore */ }
    if (sessionMode !== 'dedicated-window') {
        try { await tmuxExecAsync(['select-pane', '-t', leaderPaneId]); } catch { /* ignore */ }
    }
    await sleep(300);
    return { sessionName: teamTarget, leaderPaneId, workerPanes, sessionMode };
}

/**
 * Add ONE worker pane to an ALREADY-LIVE team session (mid-session add-worker).
 *
 * This is deliberately NOT `createTeamSession`: that function calls
 * `detectTeamMultiplexerContext()` which reads the CALLER's `env.TMUX`
 * (tmux-session.js ~line 197). The `add-worker` process runs outside the
 * team's tmux session, so reusing createTeamSession would spawn a second,
 * orphan session. Here we split directly off an existing worker pane whose
 * id we already hold from the manifest — no context detection needed.
 *
 * Splits a new pane anchored on `anchorPaneId` at `worker.cwd`, labels it via
 * the pane-scoped `@worker_name` option (the same option pane-border-format
 * reads), then re-tiles the whole team window so the new pane fits the grid.
 *
 * Returns { paneId } for the freshly created pane.
 */
export async function addWorkerPane(sessionName, anchorPaneId, worker, _options = {}) {
    if (!worker?.cwd) throw new Error(`Worker '${worker?.name}' missing cwd`);
    const splitResult = await tmuxCmdAsync([
        'split-window', '-h', '-t', anchorPaneId,
        '-d', '-P', '-F', '#{pane_id}',
        '-c', worker.cwd,
    ]);
    const paneId = splitResult.stdout.split('\n')[0]?.trim();
    if (!paneId) {
        throw new Error(`tmux split-window did not return a pane id for worker '${worker.name}'`);
    }
    try {
        await tmuxExecAsync(['set-option', '-p', '-t', paneId, '@worker_name', worker.name]);
    } catch { /* ignore — title is cosmetic */ }
    await applyTeamLayout(sessionName);
    return { paneId };
}

/**
 * Spawn a worker CLI in a specific pane.
 */
export async function spawnWorkerInPane(_sessionName, paneId, config, opts = {}) {
    validateTeamName(config.teamName);
    const startCmd = buildWorkerStartCommand(config);
    // Let the pane's shell finish its rc files before typing: an rc question
    // ("[Y/n]") reads one key from the tty and would eat the command's first
    // character. If such a question is up, wait for the user to answer it.
    const capture = opts.capturePane ?? capturePaneAsync;
    const settled = await waitForPaneSettled(paneId, capture, opts);
    if (paneHasChoicePrompt(settled)) {
        console.warn(`[my-team] pane ${paneId} (worker '${config.workerName ?? '?'}') is waiting on a shell prompt: ${lastLine(settled)} — answer it in that pane; waiting before launching the worker...`);
        if (!await waitForChoicePromptClear(paneId, capture, opts)) {
            console.warn(`[my-team] worker '${config.workerName ?? '?'}' NOT launched: the prompt in pane ${paneId} was not answered. After answering it, run this in that pane:\n${startCmd}`);
            return false;
        }
    }
    const exec = opts.tmuxExec ?? tmuxExecAsync;
    await exec(['send-keys', '-t', paneId, '-l', startCmd]);
    await exec(['send-keys', '-t', paneId, 'Enter']);
    return true;
}

function lastLine(captured) {
    const lines = captured.split('\n').map((l) => l.trim()).filter(Boolean);
    return JSON.stringify((lines[lines.length - 1] ?? '').slice(0, 120));
}

// ponytail: "settled" = two identical non-empty captures in a row. A shell that
// paints a prompt and asks its rc question later than the settle window (e.g. an
// instant-prompt theme) can still race; the answer-prompt guard in sendToWorker
// is the backstop.
async function waitForPaneSettled(paneId, capture, opts = {}) {
    const timeoutMs = opts.settleTimeoutMs ?? 5000;
    const pollMs = opts.pollIntervalMs ?? 300;
    const deadline = Date.now() + timeoutMs;
    let prev = null;
    while (Date.now() < deadline) {
        const cur = await capture(paneId);
        if (cur.trim() !== '' && cur === prev) return cur;
        prev = cur;
        await sleep(pollMs);
    }
    return prev ?? '';
}

async function waitForChoicePromptClear(paneId, capture, opts = {}) {
    const envTimeout = Number.parseInt(process.env.MY_TEAM_SHELL_READY_TIMEOUT_MS ?? '', 10);
    const timeoutMs = opts.promptTimeoutMs ?? (Number.isFinite(envTimeout) && envTimeout > 0 ? envTimeout : 30_000);
    const pollMs = opts.pollIntervalMs ?? 300;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        await sleep(pollMs);
        if (!paneHasChoicePrompt(await capture(paneId))) return true;
    }
    return false;
}

function normalizeTmuxCapture(value) {
    return value.replace(/\r/g, '').replace(/\s+/g, ' ').trim();
}

async function capturePaneAsync(paneId) {
    try {
        const result = await tmuxExecAsync(['capture-pane', '-t', paneId, '-p', '-S', '-80']);
        return result.stdout;
    } catch {
        return '';
    }
}

function paneHasTrustPrompt(captured) {
    const lines = captured.split('\n').map((l) => l.replace(/\r/g, '').trim()).filter((l) => l.length > 0);
    const tail = lines.slice(-12);
    return tail.some((l) => /Do you trust the contents of this directory\?/i.test(l)) &&
        tail.some((l) => /Yes,\s*continue|No,\s*quit|Press enter to continue/i.test(l));
}

/**
 * True when the worker CLI is showing a TOOL-PERMISSION modal — the numbered
 * "Do you want to … ? / ❯ 1. Yes / 2. … / 3. No" dialog Claude Code raises
 * before running a tool (edit/overwrite/run/fetch/…). This is NOT the
 * directory-trust prompt (see paneHasTrustPrompt) and NOT a normal input line.
 *
 * Why this matters for messaging: while this modal is up, the input line does
 * not accept text and a bare Enter SELECTS the highlighted option (e.g. "1.
 * Yes"). So sending a worker a message during a permission modal both loses the
 * message AND silently approves whatever the worker was asking about. sendTo
 * Worker must wait for the modal to clear instead of typing into it.
 *
 * Detection uses the version-stable invariants observed across Read/Edit/Write
 * permission modals: a "Do you want to …?" question line, a "❯ N. Yes" / "N.
 * No" numbered menu, and the "Esc to cancel" footer. We require the menu plus
 * either the question or the footer so a stray "Do you want to" inside ordinary
 * transcript text cannot false-positive.
 */
export function paneHasPermissionPrompt(captured) {
    const lines = captured.split('\n').map((l) => l.replace(/\r/g, '').trim()).filter((l) => l.length > 0);
    const tail = lines.slice(-14);
    const hasNumberedYes = tail.some((l) => /^[❯>]?\s*1\.\s*Yes\b/i.test(l));
    const hasNumberedNo = tail.some((l) => /^\s*\d+\.\s*No\b/i.test(l));
    const hasMenu = hasNumberedYes && hasNumberedNo;
    if (!hasMenu) return false;
    const hasQuestion = tail.some((l) => /Do you want to .+\?/i.test(l));
    const hasFooter = tail.some((l) => /Esc to cancel/i.test(l));
    return hasQuestion || hasFooter;
}

/**
 * True when the pane is waiting on a question that a stray keystroke would
 * ANSWER — broader than paneHasPermissionPrompt:
 *   - a shell y/n prompt on the last line ("[oh-my-zsh] Would you like to
 *     update? [Y/n]") — it reads ONE key, so typing the worker start command
 *     loses its first character and leaves the shell stuck at `quote>`;
 *   - a numbered menu with a highlighted first option ("› 1. Update now" /
 *     "  2. Skip") — a bare Enter picks option 1 (this is how a startup
 *     notice once ran a CLI self-update).
 * The permission modal and the trust prompt also match; callers that handle
 * those specially must check them first.
 */
export function paneHasChoicePrompt(captured) {
    const lines = captured.split('\n').map((l) => l.replace(/\r/g, '').trim()).filter((l) => l.length > 0);
    const tail = lines.slice(-14);
    const last = tail[tail.length - 1] ?? '';
    if (/[[(]\s*y\s*\/\s*n\s*[\])]\s*[:?]?\s*$/i.test(last)) return true;
    const highlightedFirst = tail.some((l) => /^[›❯]\s*1\.\s+\S/u.test(l));
    const secondOption = tail.some((l) => /^2\.\s+\S/.test(l));
    return highlightedFirst && secondOption;
}

function paneIsBootstrapping(captured) {
    const lines = captured.split('\n').map((l) => l.replace(/\r/g, '').trim()).filter((l) => l.length > 0);
    return lines.some((l) =>
        /\b(loading|initializing|starting up)\b/i.test(l) ||
        /\bmodel:\s*loading\b/i.test(l) ||
        /\bconnecting\s+to\b/i.test(l)
    );
}

export function paneHasActiveTask(captured) {
    const lines = captured.split('\n').map((l) => l.replace(/\r/g, '').trim()).filter((l) => l.length > 0);
    const tail = lines.slice(-40);
    if (tail.some((l) => /\b\d+\s+background terminal running\b/i.test(l))) return true;
    if (tail.some((l) => /esc to interrupt/i.test(l))) return true;
    if (tail.some((l) => /\bbackground terminal running\b/i.test(l))) return true;
    return false;
}

export function paneLooksReady(captured) {
    const content = captured.trimEnd();
    if (content === '') return false;
    const lines = content.split('\n').map((l) => l.replace(/\r/g, '').trimEnd()).filter((l) => l.trim() !== '');
    if (lines.length === 0) return false;
    if (paneIsBootstrapping(content)) return false;
    const lastLine = lines[lines.length - 1];
    if (/^\s*[›>❯]\s*/u.test(lastLine)) return true;
    return lines.some((l) => /^\s*›\s*/u.test(l)) || lines.some((l) => /^\s*❯\s*/u.test(l));
}

export async function waitForPaneReady(paneId, opts = {}) {
    const envTimeout = Number.parseInt(process.env.MY_TEAM_SHELL_READY_TIMEOUT_MS ?? '', 10);
    const timeoutMs = Number.isFinite(opts.timeoutMs) && (opts.timeoutMs ?? 0) > 0
        ? Number(opts.timeoutMs)
        : (Number.isFinite(envTimeout) && envTimeout > 0 ? envTimeout : 30_000);
    const pollIntervalMs = Number.isFinite(opts.pollIntervalMs) && (opts.pollIntervalMs ?? 0) > 0
        ? Number(opts.pollIntervalMs) : 250;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const captured = await capturePaneAsync(paneId);
        // A permission modal ("❯ 1. Yes") starts with ❯, so paneLooksReady
        // mistakes it for an idle prompt. Treat it as not-ready: messaging into
        // it would lose the text and the Enter would select an option.
        if (paneLooksReady(captured) && !paneHasActiveTask(captured) && !paneHasChoicePrompt(captured)) return true;
        await sleep(pollIntervalMs);
    }
    console.warn(`[tmux-session] waitForPaneReady: pane ${paneId} timed out after ${timeoutMs}ms`);
    return false;
}

function paneTailContainsLiteralLine(captured, text) {
    return normalizeTmuxCapture(captured).includes(normalizeTmuxCapture(text));
}

/**
 * True if `message` is still sitting UNSENT in the worker's input line.
 *
 * Why not paneTailContainsLiteralLine: once a message is submitted, the worker
 * CLI echoes it into the transcript (e.g. "❯ <message>" scrollback, or the
 * agent quoting it back). A whole-screen substring match then reports the
 * message as "still there" forever — so sendToWorker returns false on a
 * delivery that actually succeeded and keeps firing pointless Enters.
 *
 * The input line is the LAST prompt-marker line on screen (❯ / › / >) plus the
 * wrapped continuation rows beneath it (a long line that overflowed the pane
 * width). We reconstruct only that region and check whether the message text
 * survives there. Transcript echoes above the final prompt are ignored.
 */
export function messageStillInInputLine(captured, message) {
    const rows = captured.replace(/\r/g, '').split('\n').map((l) => l.replace(/\s+$/u, ''));
    // Find the last line that opens with a prompt marker.
    let promptIdx = -1;
    for (let i = rows.length - 1; i >= 0; i--) {
        if (/^\s*[›>❯]\s?/u.test(rows[i])) { promptIdx = i; break; }
    }
    if (promptIdx === -1) {
        // No prompt marker visible (e.g. a modal/transcript fills the tail);
        // fall back to the legacy whole-screen check rather than guess.
        return paneTailContainsLiteralLine(captured, message);
    }
    // Collect the prompt line + following non-empty rows until a UI boundary
    // (border line of ─/═, or a status/footer line). Those rows are the
    // wrapped remainder of what the user is still typing.
    const region = [rows[promptIdx].replace(/^\s*[›>❯]\s?/u, '')];
    for (let i = promptIdx + 1; i < rows.length; i++) {
        const line = rows[i];
        if (line.trim() === '') break;
        if (/^[\s─═-]+$/u.test(line)) break;
        region.push(line);
    }
    return normalizeTmuxCapture(region.join(' ')).includes(normalizeTmuxCapture(message));
}

async function paneInCopyMode(paneId) {
    try {
        const result = await tmuxCmdAsync(['display-message', '-t', paneId, '-p', '#{pane_in_mode}']);
        return result.stdout.trim() === '1';
    } catch {
        return false;
    }
}

/**
 * Block until a tool-permission modal in `paneId` clears, or the timeout
 * elapses. We intentionally send NO keys while it is up — a stray Enter would
 * select an option (approving/denying whatever the worker asked). The user or
 * the worker itself owns that decision; we just wait for it to be made.
 *
 * Returns true once the modal is gone, false if it was still up at the
 * deadline (caller should then refuse to send rather than type into it).
 */
async function waitForPermissionPromptClear(paneId, timeoutMs = 30_000, pollIntervalMs = 300) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (!paneHasPermissionPrompt(await capturePaneAsync(paneId))) return true;
        await sleep(pollIntervalMs);
    }
    return false;
}

/**
 * Send a short trigger message to a worker pane via tmux send-keys.
 * Robust against busy panes / copy-mode / trust prompts / permission modals.
 * Returns false on failure (does not throw). Message must be <= 500 chars.
 *
 * The cap is 500 (was 200) because a worker's join/startup notice embeds the
 * absolute path to its AGENTS.md overlay, and that path scales with team name
 * (<=50) + worker name (unbounded by WORKER_NAME_PATTERN) + an arbitrary
 * --state-root. The worst realistic notice is ~400 chars; 500 leaves margin
 * while staying short enough for a single safe tmux send-keys -l injection.
 */
export async function sendToWorker(_sessionName, paneId, message) {
    if (message.length > 500) {
        console.warn(`[tmux-session] sendToWorker: message rejected (${message.length} chars exceeds 500 char limit)`);
        return false;
    }
    try {
        const sendKey = async (key) => {
            await tmuxExecAsync(['send-keys', '-t', paneId, key]);
        };
        if (await paneInCopyMode(paneId)) return false;

        // A tool-permission modal is up: typing text does nothing and Enter
        // selects an option. Wait for the worker/user to answer it before we
        // touch the pane; bail if it never clears so we never approve by proxy.
        if (paneHasPermissionPrompt(await capturePaneAsync(paneId))) {
            if (!await waitForPermissionPromptClear(paneId)) {
                console.warn(`[tmux-session] sendToWorker: pane ${paneId} has an unanswered permission modal; not sending`);
                return false;
            }
        }

        const initialCapture = await capturePaneAsync(paneId);
        const paneBusy = paneHasActiveTask(initialCapture);
        if (paneHasTrustPrompt(initialCapture)) {
            await sendKey('C-m'); await sleep(120); await sendKey('C-m'); await sleep(200);
        } else if (paneHasChoicePrompt(initialCapture)) {
            // Some other question (shell y/n, CLI update menu): our Enter would
            // answer it. Leave it to the user.
            console.warn(`[tmux-session] sendToWorker: pane ${paneId} is waiting on a prompt (${lastLine(initialCapture)}); not sending — answer it in that pane`);
            return false;
        }

        await tmuxExecAsync(['send-keys', '-t', paneId, '-l', '--', message]);
        await sleep(150);

        for (let round = 0; round < 6; round++) {
            await sleep(100);
            // The worker may have raised a permission modal between rounds (e.g.
            // it started acting on the text we just typed). Sending Enter now
            // would pick a modal option, not submit our line — wait it out.
            const roundCapture = await capturePaneAsync(paneId);
            if (paneHasPermissionPrompt(roundCapture)) {
                if (!await waitForPermissionPromptClear(paneId)) return false;
                continue;
            }
            if (paneHasChoicePrompt(roundCapture)) {
                console.warn(`[tmux-session] sendToWorker: pane ${paneId} raised a prompt (${lastLine(roundCapture)}); not pressing Enter — answer it in that pane`);
                return false;
            }
            if (round === 0 && paneBusy) {
                await sendKey('Tab'); await sleep(80); await sendKey('C-m');
            } else {
                await sendKey('C-m'); await sleep(200); await sendKey('C-m');
            }
            await sleep(140);
            const check = await capturePaneAsync(paneId);
            // Submitted once the message leaves the INPUT line — not merely once
            // it disappears from the whole screen (the transcript keeps an echo).
            if (!messageStillInInputLine(check, message)) return true;
            await sleep(140);
        }

        if (await paneInCopyMode(paneId)) return false;
        await sendKey('C-m'); await sleep(120); await sendKey('C-m'); await sleep(140);
        const final = await capturePaneAsync(paneId);
        if (!final || final.trim() === '') return false;
        return !messageStillInInputLine(final, message);
    } catch {
        return false;
    }
}

export async function injectToLeaderPane(_sessionName, leaderPaneId, message) {
    const prefixed = `[MY_TEAM_INJECT] ${message}`.slice(0, 200);
    try {
        if (await paneInCopyMode(leaderPaneId)) return false;
        const captured = await capturePaneAsync(leaderPaneId);
        if (paneHasActiveTask(captured)) {
            await tmuxExecAsync(['send-keys', '-t', leaderPaneId, 'C-c']);
            await sleep(250);
        }
    } catch { /* best-effort */ }
    return sendToWorker('', leaderPaneId, prefixed);
}

function isTmuxPaneNotFoundError(error) {
    const err = error;
    const text = [err?.stderr, err?.stdout, err?.message]
        .filter((p) => typeof p === 'string').join('\n').toLowerCase();
    return /can't find pane|can't find window|can't find session|no such pane|pane not found|unknown pane/.test(text);
}

export async function getWorkerLiveness(paneId) {
    try {
        const result = await tmuxCmdAsync(['display-message', '-t', paneId, '-p', '#{pane_dead}']);
        return result.stdout.trim() === '0' ? 'alive' : 'dead';
    } catch (error) {
        return isTmuxPaneNotFoundError(error) ? 'dead' : 'unknown';
    }
}

export async function isWorkerAlive(paneId) {
    return (await getWorkerLiveness(paneId)) === 'alive';
}

/**
 * Kill worker panes immediately. Never kills the leader. (The old
 * sentinel + grace wait is gone: no worker ever acknowledged it.)
 */
export async function killWorkerPanes(opts) {
    const { paneIds, leaderPaneId } = opts;
    for (const paneId of paneIds) {
        if (paneId === leaderPaneId) continue;
        try { await tmuxExecAsync(['kill-pane', '-t', paneId]); } catch { /* gone */ }
    }
}

/**
 * Kill the team session entirely (for detached-session/dedicated-window),
 * or kill worker panes only (for split-pane), preserving the user's host
 * pane. The host pane is not an orchestrator — it is the pane the user ran
 * `my-team start` from and continues to type in after shutdown.
 */
export async function killTeamSession(sessionName, workerPaneIds, leaderPaneId, options = {}) {
    const sessionMode = options.sessionMode
        ?? (sessionName.includes(':') ? 'split-pane' : 'detached-session');
    if (sessionMode === 'split-pane') {
        if (!workerPaneIds?.length) return;
        for (const id of workerPaneIds) {
            if (id === leaderPaneId) continue;
            try { await tmuxExecAsync(['kill-pane', '-t', id]); } catch { /* gone */ }
        }
        return;
    }
    if (sessionMode === 'dedicated-window') {
        try { await tmuxExecAsync(['kill-window', '-t', sessionName]); } catch { /* gone */ }
        return;
    }
    const sessionTarget = sessionName.split(':')[0] ?? sessionName;
    if (process.env.MY_TEAM_ALLOW_KILL_CURRENT_SESSION !== '1' && process.env.TMUX) {
        try {
            const current = await tmuxCmdAsync(['display-message', '-p', '#S']);
            if (current.stdout.trim() === sessionTarget) return;
        } catch { /* best effort */ }
    }
    try { await tmuxExecAsync(['kill-session', '-t', sessionTarget]); } catch { /* gone */ }
}

/** True if pane id matches the `%N` tmux pane-id format. */
export function isPaneId(value) {
    return typeof value === 'string' && /^%\d+$/.test(value.trim());
}

export { existsSync };
