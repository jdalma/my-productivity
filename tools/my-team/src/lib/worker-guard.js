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
import { existsSync, writeFileSync } from 'fs';
import { homedir } from 'os';
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
const GIT_FLAGS = new Set(['-h', '-p', '-P', '--paginate', '--no-pager', '--bare', '--no-replace-objects', '--literal-pathspecs',
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
/** Marks in a lexed line: a subshell's start and end (its `cd` stays inside), and where a substitution stood in a word. */
const OPEN = ['\u0000('], CLOSE = ['\u0000)'];
const SUBST = '\u0001';

function lex(src) {
    const cmds = [], subs = [];
    let words = [], word = null, i = 0, ok = true;
    const endWord = () => { if (word !== null) words.push(word); word = null; };
    // each simple command keeps the operator that ended it (`.sep`): what follows a cd depends on it
    const endCmd = (sep = null) => { endWord(); if (words.length) { words.sep = sep; cmds.push(words); } words = []; };
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
        else if (c === '(' || c === ')') { endCmd(); cmds.push(c === '(' ? OPEN : CLOSE); i++; }
        else if ((c === '&' || c === '|') && src[i + 1] === c) { endCmd(c + c); i += 2; }
        else if (c === '\n' || c === ';' || c === '&' || c === '|') { endCmd(c); i++; }
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
                if (d === '\\') { s += src[i + 1] ?? ''; i += 2; } else if (d === '$' && src[i + 1] === '(') { i += 2; balanced(); s += SUBST; }
                else if (d === '`') { i++; backtick(); s += SUBST; } else { s += d; i++; }
            }
            add(s);
        } else if ((c === '$' || c === '<' || c === '>') && src[i + 1] === '(') { i += 2; balanced(); add(SUBST); }
        else if (c === '`') { i++; backtick(); add(SUBST); }
        else { add(c); i++; }
    }
    endCmd();
    return { cmds, subs, ok };
}

/** A word whose value is known only when the line runs: a variable, a substitution, or nothing. */
function unknownWord(w) {
    return w === '' || w.includes('$') || w.includes(SUBST);
}

const ASSIGNMENT = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s;

/**
 * The commands a list of words runs, past assignments and wrappers: `{ name, args, env }` (env: the
 * assignments before it) or `{ text }` (a command given to a wrapper as one string). A wrapper's options
 * may take values (`env -u X`, `nice -n 10`, `find -name sh`) that no table here could list for every
 * tool: after a wrapper, every word naming git, a shell or eval starts a command (R60 R1, R60a R1), and a
 * word with a space before the first of them (`watch "git push"`, `env -S "…"`) is read as a command line.
 */
function commandsOf(words, env = {}) {
    let k = 0;
    const vars = { ...env };
    for (; k < words.length; k++) {
        const m = ASSIGNMENT.exec(words[k]);
        if (!m) break;
        vars[m[1]] = m[2];
    }
    if (k >= words.length) return [];
    const name = basename(words[k]);
    if (!WRAPPERS.has(name)) return [{ name, args: words.slice(k + 1), env: vars }];
    const out = [];
    let first = -1;
    for (let j = k + 1; j < words.length; j++) {
        if (RUNNERS.has(basename(words[j]))) {
            if (first < 0) first = j;
            const between = Object.fromEntries(words.slice(k + 1, j).map((w) => ASSIGNMENT.exec(w)).filter(Boolean).map((m) => [m[1], m[2]]));
            out.push(...commandsOf(words.slice(j), { ...vars, ...between }));
        }
    }
    for (const w of words.slice(k + 1, first < 0 ? words.length : first)) if (/\s/.test(w)) out.push({ text: w });
    return out;
}

function expandHome(p) {
    return p === '~' ? homedir() : p.startsWith('~/') ? join(homedir(), p.slice(2)) : p;
}

/** The folder after `cd`/`pushd` with `args` from `dir`; null when it cannot be told. */
function cdTarget(args, dir) {
    const rest = args.filter((a) => a !== '-L' && a !== '-P' && a !== '--');
    if (rest.length === 0) return homedir();
    const to = rest[0];
    if (to === '-' || unknownWord(to) || (to.startsWith('~') && !to.startsWith('~/') && to !== '~')) return null;
    if (dir === null && !isAbsolute(expandHome(to))) return null;
    return resolve(dir ?? '/', expandHome(to));
}

/**
 * What a git command line does: `sub` (null: none; undefined: cannot be told — an unknown option, a -c alias,
 * a subcommand or an option value from a variable), the folders it acts on (`-C` from `dir`, `--git-dir`,
 * `--work-tree`, GIT_DIR, GIT_WORK_TREE; null entries where unknown) and whether it only asks for help.
 */
function gitCall(args, env, dir) {
    let cdir = dir;
    const extra = [], config = [];
    const at = (v) => (cdir === null && !isAbsolute(expandHome(v)) ? null : resolve(cdir ?? '/', expandHome(v)));
    for (const key of ['GIT_DIR', 'GIT_WORK_TREE']) if (env[key] !== undefined) extra.push(unknownWord(env[key]) ? null : at(env[key]));
    for (let k = 0; k < args.length; k++) {
        const a = args[k];
        if (unknownWord(a)) return { sub: undefined };
        if (!a.startsWith('-')) {
            const rest = args.slice(k + 1);
            return { sub: a, rest, targets: [cdir, ...extra], config, help: rest.includes('-h') || rest.includes('--help') };
        }
        if (GIT_FLAGS.has(a)) continue;
        const name = a.split('=')[0];
        if (!GIT_WITH_ARG.has(name)) return { sub: undefined };
        const value = a.includes('=') ? a.slice(a.indexOf('=') + 1) : args[++k];
        if (value === undefined) return { sub: undefined };
        // a folder from a variable leaves the target unknown, not the subcommand
        const folder = unknownWord(value) ? null : at(value);
        if (name === '-C') { cdir = folder; continue; }
        if (name === '--git-dir' || name === '--work-tree') { extra.push(folder); continue; }
        if (name === '-c' || name === '--config-env') config.push(value.split('=')[0].toLowerCase());
        if (unknownWord(value) || (name === '-c' && /^alias\./i.test(value))) return { sub: undefined };
    }
    return { sub: null, targets: [] };
}

function gitCommonDir(dir) {
    try {
        return pathKey(execFileSync('git', ['-C', dir, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
            { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim());
    } catch { return null; }
}

/** The URLs a push to `repo` from `dir` goes to: a remote's push URLs, or `repo` itself; insteadOf applied. */
function pushUrls(dir, repo) {
    const git = (...args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    try { return git('remote', 'get-url', '--push', '--all', repo).split('\n').filter(Boolean); } catch { /* not a remote name */ }
    try { return [git('ls-remote', '--get-url', repo)]; } catch { return []; }
}

/** The remote a bare `git push` in `dir` uses, as git chooses it (git-push(1), git-config(1)). */
function defaultPushRemote(dir) {
    const get = (key) => { try { return execFileSync('git', ['-C', dir, 'config', '--get', key], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; } };
    let branch = '';
    try { branch = execFileSync('git', ['-C', dir, 'symbolic-ref', '--short', '-q', 'HEAD'], { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { /* detached */ }
    return (branch && get(`branch.${branch}.pushRemote`)) || get('remote.pushDefault') || (branch && get(`branch.${branch}.remote`)) || 'origin';
}

/** A URL's local path (relative ones from `dir`), or null for a server: `scheme://` other than file, or scp-like `host:path`. */
function localPath(url, dir) {
    if (/^file:\/\//i.test(url)) return url.slice('file://'.length);
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(url) || /^[^/]*:/.test(url)) return null;
    return resolve(dir, url);
}

/**
 * Whether `git push <args>` from `dir` goes only to local repositories other than the protected one (T59c,
 * R60b R1): the point of `push` is that nothing leaves for a server, and a clone's push to one leaves just the
 * same; a local clone of the protected repository pushing back into it changes it just the same.
 */
function pushStaysLocal(args, dir, protectedRepo) {
    let repo = null;
    const positional = [];
    for (let k = 0; k < args.length; k++) {
        const a = args[k];
        if (unknownWord(a)) return false;
        if (a === '--') { positional.push(...args.slice(k + 1)); break; }
        if (a.startsWith('--repo=')) { repo = a.slice('--repo='.length); continue; }
        if (['--repo', '-o', '--push-option', '--receive-pack', '--exec'].includes(a)) {
            const value = args[++k];
            if (value === undefined || unknownWord(value)) return false;
            if (a === '--repo') repo = value;
            continue;
        }
        if (!a.startsWith('-')) positional.push(a);
    }
    const urls = pushUrls(dir, positional[0] ?? repo ?? defaultPushRemote(dir));
    if (urls.length === 0) return false;
    return urls.every((url) => {
        const path = localPath(url, dir);
        return path !== null && !touchesProtected([path], protectedRepo);
    });
}

/**
 * Whether a git command acting on `targets` touches the protected repository (R60a L2): a folder inside it
 * (symlinks and case followed), one sharing its git data (a worktree of it elsewhere, its .git), or one that
 * cannot be told. Without a protected repository every git command counts as touching it.
 */
function touchesProtected(targets, protectedRepo) {
    if (!protectedRepo) return true;
    const root = pathKey(protectedRepo.root);
    for (const t of targets) {
        if (t === null) return true;
        const key = pathKey(t);
        if (key === root || key.startsWith(root + sep)) return true;
        if (protectedRepo.common && (key === protectedRepo.common || key.startsWith(protectedRepo.common + sep))) return true;
        if (existsSync(t) && gitCommonDir(t) === protectedRepo.common) return true;
    }
    return false;
}

/**
 * The first rule of `rules` that `command` breaks, as `{ rule, reason }`, or null. `cwd` is where the
 * command starts and `repoRoot` the protected repository: git commands acting elsewhere (a scratch clone,
 * a local bare remote) pass. Without `repoRoot` every git push and write counts.
 */
export function bashDenial(command, rules, { cwd = null, repoRoot = null } = {}) {
    if (rules.length === 0) return null;
    const protectedRepo = repoRoot ? { root: repoRoot, common: gitCommonDir(repoRoot) } : null;
    return denial(command, rules, cwd, protectedRepo);
}

function denial(command, rules, start, protectedRepo) {
    const { cmds, subs, ok } = lex(command);
    if (!ok && rules.includes('push') && /\bpush\b/.test(command)) return { rule: 'push', reason: 'an unclosed quote or substitution around push' };
    let dir = start, moved = false, gitEnvUnknown = false, gitConfigUnknown = false;
    const outer = [];
    const judge = (cmd) => {
        if (cmd.text !== undefined) return denial(cmd.text, rules, dir, protectedRepo);
        if (cmd.name === 'cd' || cmd.name === 'pushd' || cmd.name === 'popd') {
            // in a pipe or in the background the cd runs in a subshell of its own (R60b L1)
            if (cmd.sep === '|' || cmd.sep === '&') return null;
            const to = cmd.name === 'popd' ? null : cdTarget(cmd.args, dir);
            // after `;`, a newline or `||`, a cd that fails still lets the rest run where the line was:
            // only a folder there now is certain (R60b M1); after `&&` the rest runs only if the cd worked
            dir = cmd.sep === '&&' || (to !== null && existsSync(to)) ? to : null;
            moved = true;
            return null;
        }
        if (['export', 'declare', 'typeset', 'set'].includes(cmd.name)) {
            // an exported git location reaches every git after it in ways not followed here (R60b L2); `set`
            // exports only with allexport (-a), not with -e, -u, -o pipefail (R60c R1)
            const allexport = cmd.name === 'set' && cmd.args.some((a, i) => /^-[A-Za-z]*a/.test(a) || (a === '-o' && cmd.args[i + 1] === 'allexport'));
            if (allexport || cmd.args.some((a) => /^(GIT_DIR|GIT_WORK_TREE)(=|$)/.test(a))) gitEnvUnknown = true;
            if (allexport || cmd.args.some((a) => /^GIT_CONFIG/.test(a))) gitConfigUnknown = true;
            return null;
        }
        if (SHELLS.has(cmd.name)) {
            const flag = cmd.args.findIndex((a) => /^-[a-z]*c[a-z]*$/.test(a));
            return flag >= 0 && cmd.args[flag + 1] !== undefined ? denial(cmd.args[flag + 1], rules, dir, protectedRepo) : null;
        }
        if (cmd.name === 'eval') return denial(cmd.args.join(' '), rules, dir, protectedRepo);
        if (cmd.name !== 'git') return null;
        const git = gitCall(cmd.args, cmd.env, dir);
        if (gitEnvUnknown && git.targets) git.targets.push(null);
        if (git.sub === undefined) return { rule: rules[0], reason: 'a git command it cannot read (unknown option, -c alias, or a value from a variable)' };
        if (git.sub === null || git.help) return null;
        const pushes = git.sub === 'push' || git.sub === 'send-pack' || (git.sub === 'subtree' && git.rest.includes('push'));
        const rule = rules.includes('push') && pushes ? 'push' : rules.includes('repo-write') && GIT_WRITES.has(git.sub) ? 'repo-write' : null;
        if (!rule) return null;
        if (touchesProtected(git.targets, protectedRepo)) return { rule, reason: `git ${git.sub} in the protected repository` };
        // outside it, a push still must stay on this machine (T59c); send-pack and subtree are not read that far
        // config that can move a push elsewhere (pushurl, insteadOf, pushRemote, push.default) is not followed (R60c R2)
        const redirected = gitConfigUnknown || Object.keys(cmd.env).some((k) => k.startsWith('GIT_CONFIG'))
            || git.config.some((k) => /^(remote|url|branch|push)\./.test(k));
        if (rule === 'push' && (redirected || !(git.sub === 'push' && git.targets.length === 1 && pushStaysLocal(git.rest, git.targets[0], protectedRepo)))) {
            return { rule, reason: `git ${git.sub} to a destination not certainly local` };
        }
        return null;
    };
    for (const words of cmds) {
        if (words === OPEN) { outer.push(dir); continue; }
        if (words === CLOSE) { if (outer.length) dir = outer.pop(); continue; }
        for (const cmd of commandsOf(words)) {
            cmd.sep = words.sep;
            const found = judge(cmd);
            if (found) return found;
        }
    }
    // a substitution runs where the line was when it ran: known only when the line never moved
    for (const sub of subs) {
        const found = denial(sub, rules, moved ? null : start, protectedRepo);
        if (found) return found;
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
