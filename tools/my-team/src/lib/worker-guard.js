/**
 * Per-worker deny rules, kept by a Claude Code PreToolUse hook (T59). A rule is a device, not a sentence in
 * AGENTS.md: the hook runs before every Bash, Edit, Write and NotebookEdit call, also with permission checks
 * skipped, and exit 2 stops the call.
 *
 * - `push`: a Bash command that runs `git push`, in any of the shell forms below.
 * - `repo-write`: an edit inside the git repository of the worker's cwd, or a git command that changes a
 *   repository (commit, add, stash, checkout, reset, ...).
 *
 * The hook reads the command string. What a script, an alias or a Makefile runs is not seen: this guards
 * against mistakes, not intent. A form it cannot read is refused.
 */

import { execFileSync } from 'child_process';
import { writeFileSync } from 'fs';
import { basename, isAbsolute, join, resolve, sep } from 'path';
import { fileURLToPath } from 'url';

import { pathKey } from './tmux-guard.js';

export const DENY_RULES = ['push', 'repo-write'];

const HOOK = fileURLToPath(new URL('../worker-guard-hook.js', import.meta.url));

/** Words that run a command given later on the line (after options of their own, some taking values). */
const WRAPPERS = new Set(['command', 'builtin', 'exec', 'nohup', 'time', 'sudo', 'env', 'nice', 'xargs', 'timeout',
    'find', 'watch', 'parallel', 'npx', 'then', 'do', 'else', 'elif', 'if', 'while', 'until', '!', '{', '}']);
const SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh']);
/** The commands the rules look into. */
const RUNNERS = new Set(['git', 'eval', ...SHELLS]);

/** git's own options before the subcommand (git(1)); a value follows those in GIT_WITH_ARG. */
const GIT_FLAGS = new Set(['-p', '-P', '--paginate', '--no-pager', '--bare', '--no-replace-objects', '--literal-pathspecs',
    '--glob-pathspecs', '--noglob-pathspecs', '--icase-pathspecs', '--no-optional-locks', '--no-lazy-fetch', '--no-advice',
    '--html-path', '--man-path', '--info-path', '--version', '--help']);
const GIT_WITH_ARG = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--config-env', '--super-prefix']);

/** Subcommands that change a repository's files, index, refs or stash. */
const GIT_WRITES = new Set(['commit', 'add', 'stash', 'checkout', 'reset', 'restore', 'switch', 'rm', 'mv', 'merge',
    'rebase', 'cherry-pick', 'revert', 'pull', 'am', 'apply', 'clean', 'commit-tree', 'update-ref', 'update-index']);

/**
 * A command line as the shell splits it: simple commands (lists of words, quotes removed) and the command
 * substitutions found anywhere, which run too. `ok` is false when a quote or a substitution is not closed.
 */
function lex(src) {
    const cmds = [], subs = [];
    let words = [], word = null, i = 0, ok = true;
    const endWord = () => { if (word !== null) words.push(word); word = null; };
    const endCmd = () => { endWord(); if (words.length) cmds.push(words); words = []; };
    const add = (s) => { word = (word ?? '') + s; };
    /** From after `$(` (or `<(`), the text up to its `)`, quotes and nesting followed. */
    const balanced = () => {
        let depth = 1, j = i, q = null;
        for (; j < src.length; j++) {
            const c = src[j];
            if (q) { if (c === '\\' && q === '"') j++; else if (c === q) q = null; continue; }
            if (c === "'" || c === '"') q = c;
            else if (c === '\\') j++;
            else if (c === '(') depth++;
            else if (c === ')' && --depth === 0) break;
        }
        if (j >= src.length) { ok = false; subs.push(src.slice(i)); i = src.length; return; }
        subs.push(src.slice(i, j));
        i = j + 1;
    };
    const backtick = () => {
        const j = src.indexOf('`', i);
        if (j < 0) { ok = false; subs.push(src.slice(i)); i = src.length; return; }
        subs.push(src.slice(i, j));
        i = j + 1;
    };
    while (i < src.length) {
        const c = src[i];
        if (c === ' ' || c === '\t') { endWord(); i++; }
        else if (c === '\n' || c === ';' || c === '&' || c === '|' || c === '(' || c === ')') { endCmd(); i++; }
        else if (c === '#' && word === null) { while (i < src.length && src[i] !== '\n') i++; }
        else if (c === '\\') { if (src[i + 1] !== '\n') add(src[i + 1] ?? ''); i += 2; }
        else if (c === "'") {
            const j = src.indexOf("'", i + 1);
            if (j < 0) { ok = false; add(src.slice(i + 1)); i = src.length; } else { add(src.slice(i + 1, j)); i = j + 1; }
        } else if (c === '"') {
            i++;
            let s = '';
            for (;;) {
                if (i >= src.length) { ok = false; break; }
                const d = src[i];
                if (d === '"') { i++; break; }
                if (d === '\\') { s += src[i + 1] ?? ''; i += 2; } else if (d === '$' && src[i + 1] === '(') { i += 2; balanced(); }
                else if (d === '`') { i++; backtick(); } else { s += d; i++; }
            }
            add(s);
        } else if ((c === '$' || c === '<' || c === '>') && src[i + 1] === '(') { i += 2; balanced(); add(''); }
        else if (c === '`') { i++; backtick(); add(''); }
        else { add(c); i++; }
    }
    endCmd();
    return { cmds, subs, ok };
}

/**
 * The command a list of words runs, past assignments and wrappers: `{ name, args }`, or null. A wrapper's
 * options may take values (`env -u X`, `nice -n 10`, `xargs -I {}`), which no table here could list for
 * every tool: after a wrapper, the command is the first word naming git, a shell or eval (R60 R1).
 */
function commandOf(words) {
    let k = 0;
    while (k < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[k])) k++;
    if (k >= words.length) return null;
    if (WRAPPERS.has(words[k])) {
        const next = words.findIndex((w, i) => i > k && RUNNERS.has(basename(w)));
        return next < 0 ? null : commandOf(words.slice(next));
    }
    return { name: basename(words[k]), args: words.slice(k + 1) };
}

/**
 * git's subcommand, or `undefined` when it cannot be told: an unknown option, an alias defined with -c, a
 * subcommand that is empty or starts with `$` (made by a substitution or a variable).
 */
function gitSubcommand(args) {
    for (let k = 0; k < args.length; k++) {
        const a = args[k];
        if (a === '' || a.startsWith('$')) return undefined;
        if (!a.startsWith('-')) return a;
        const name = a.split('=')[0];
        if (GIT_FLAGS.has(a)) continue;
        if (GIT_WITH_ARG.has(name)) {
            const value = a.includes('=') ? a.slice(a.indexOf('=') + 1) : args[++k];
            if (name === '-c' && /^alias\./i.test(value ?? '')) return undefined;
            continue;
        }
        return undefined;
    }
    return null;
}

/** The first rule of `rules` that `command` breaks, as `{ rule, reason }`, or null. */
export function bashDenial(command, rules) {
    if (rules.length === 0) return null;
    const { cmds, subs, ok } = lex(command);
    if (!ok && rules.includes('push') && /\bpush\b/.test(command)) return { rule: 'push', reason: 'an unclosed quote or substitution around push' };
    for (const words of cmds) {
        const cmd = commandOf(words);
        if (!cmd) continue;
        if (SHELLS.has(cmd.name)) {
            const flag = cmd.args.findIndex((a) => /^-[a-z]*c[a-z]*$/.test(a));
            if (flag >= 0 && cmd.args[flag + 1] !== undefined) {
                const inner = bashDenial(cmd.args[flag + 1], rules);
                if (inner) return inner;
            }
        } else if (cmd.name === 'eval') {
            const inner = bashDenial(cmd.args.join(' '), rules);
            if (inner) return inner;
        } else if (cmd.name === 'git') {
            const sub = gitSubcommand(cmd.args);
            if (sub === undefined) return { rule: rules[0], reason: 'a git command it cannot read (unknown option, -c alias, or a subcommand from a variable)' };
            const pushes = sub === 'push' || sub === 'send-pack' || (sub === 'subtree' && cmd.args.slice(cmd.args.indexOf(sub) + 1).includes('push'));
            if (rules.includes('push') && pushes) return { rule: 'push', reason: `git ${sub}` };
            if (rules.includes('repo-write') && GIT_WRITES.has(sub)) return { rule: 'repo-write', reason: `git ${sub}` };
        }
    }
    for (const sub of subs) {
        const inner = bashDenial(sub, rules);
        if (inner) return inner;
    }
    return null;
}

/** `repo-write` for an edit of `path` (relative to `cwd`) inside `repoRoot`, or null. */
export function pathDenial(path, cwd, repoRoot) {
    if (!repoRoot || !path) return null;
    const target = pathKey(isAbsolute(path) ? path : resolve(cwd, path));
    const root = pathKey(repoRoot);
    return target === root || target.startsWith(root + sep) ? { rule: 'repo-write', reason: `inside ${repoRoot}` } : null;
}

function shellQuote(s) {
    return `'${s.replace(/'/g, `'\\''`)}'`;
}

/**
 * The hook's command line: any failure but its own refusal (exit 2) becomes one too, so a crash never lets a
 * call through. `node` from PATH, not this process's binary: a versioned path (homebrew's Cellar) would go
 * with the next node upgrade and every tool call of the worker would be refused.
 */
export function hookCommand(deny, repoRoot) {
    return ['node', shellQuote(HOOK), '--deny', shellQuote(deny.join(',')),
        ...(repoRoot ? ['--repo', shellQuote(repoRoot)] : [])].join(' ') + ' || exit 2';
}

/**
 * The launch arguments that install a worker's deny rules: `--settings <workerDir>/guard-settings.json` for a
 * claude worker (the file written here; Claude Code adds its hooks to the user's own), none without rules.
 * Other agents have no such hook: the rules are not applied and `warning` says so.
 */
export function guardLaunch({ agentType, deny, cwd, workerDir }) {
    if (!deny?.length) return { args: [], warning: null };
    if (agentType !== 'claude') {
        return { args: [], warning: `${agentType} worker: deny (${deny.join(', ')}) is not applied — only claude workers have the hook` };
    }
    let repoRoot = null;
    try { repoRoot = execFileSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { /* not a repository */ }
    const warning = deny.includes('repo-write') && !repoRoot ? `repo-write: ${cwd} is not in a git repository; only git commands are refused` : null;
    const path = join(workerDir, 'guard-settings.json');
    writeFileSync(path, JSON.stringify({
        hooks: { PreToolUse: [{ matcher: 'Bash|Edit|Write|MultiEdit|NotebookEdit', hooks: [{ type: 'command', command: hookCommand(deny, repoRoot) }] }] },
    }, null, 2) + '\n');
    return { args: ['--settings', path], warning };
}
