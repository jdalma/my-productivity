/**
 * Per-worker deny rules, kept by a Claude Code PreToolUse hook (T59). A rule is a device, not a sentence in
 * AGENTS.md: the hook runs before every Bash, Edit, Write and NotebookEdit call, also with permission checks
 * skipped, and exit 2 stops the call.
 *
 * - `push`: a Bash command that runs `git push`, in any of the shell forms below.
 * - `repo-write`: an edit inside the git repository of the worker's cwd, or a git command that changes a
 *   repository (commit, add, stash, checkout, reset, config writes, ...).
 * - Both: the push gate stays on (T63g). No `git config` write of my-team.* or core.hooksPath reaching the
 *   repository, and no direct edit of a git config file it reads or of its hooks folder.
 *
 * The hook reads the command string. What a script, an alias or a Makefile runs is not seen: this guards
 * against mistakes, not intent. A form it cannot read is refused. A heredoc body is judged as commands
 * unless the whole line is `cat > file <<EOF` (or `>>`); an unquoted one's substitutions still run and are
 * read.
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

/**
 * The command substitutions in heredoc text, which run even when the text is data (an unquoted delimiter):
 * `$(…)` and backticks, quotes being plain text there. `ok` is false when one is not closed.
 */
function substitutionsIn(text) {
    const subs = [];
    let ok = true;
    for (let i = 0; i < text.length; i++) {
        if (text[i] === '\\') { i++; continue; }
        if (text[i] === '$' && text[i + 1] === '(') {
            let depth = 1, j = i + 2;
            for (; j < text.length && depth; j++) { if (text[j] === '(') depth++; else if (text[j] === ')') depth--; }
            if (depth) { ok = false; subs.push(text.slice(i + 2)); break; }
            subs.push(text.slice(i + 2, j - 1));
            i = j - 1;
        } else if (text[i] === '`') {
            const j = text.indexOf('`', i + 1);
            if (j < 0) { ok = false; subs.push(text.slice(i + 1)); break; }
            subs.push(text.slice(i + 1, j));
            i = j;
        }
    }
    return { subs, ok };
}

function lex(src) {
    const cmds = [], subs = [], heredocs = [];
    let words = [], word = null, i = 0, ok = true;
    // heredocs opened on this line: their bodies start after its newline (T63g)
    let pending = [];
    /** From the start of a line, each pending heredoc's body up to its delimiter line; none found: unreadable. */
    const bodies = () => {
        for (const h of pending) {
            const lines = [];
            let found = false;
            while (i < src.length) {
                const nl = src.indexOf('\n', i);
                const end = nl < 0 ? src.length : nl;
                const line = h.strip ? src.slice(i, end).replace(/^\t+/, '') : src.slice(i, end);
                i = nl < 0 ? src.length : nl + 1;
                if (line === h.delim) { found = true; break; }
                lines.push(line);
            }
            if (!found) ok = false;
            heredocs.push({ body: lines.join('\n'), quoted: h.quoted, words: h.words });
        }
        pending = [];
    };
    /** After `<<` or `<<-`: the delimiter word; quoted in any part, the body is not expanded. */
    const heredoc = () => {
        endWord();
        i += 2;
        const strip = src[i] === '-';
        if (strip) i++;
        while (src[i] === ' ' || src[i] === '\t') i++;
        let delim = '', quoted = false;
        while (i < src.length && !/[\s;&|()<>]/.test(src[i])) {
            const d = src[i];
            if (d === "'" || d === '"') {
                const j = src.indexOf(d, i + 1);
                if (j < 0) { ok = false; i = src.length; break; }
                delim += src.slice(i + 1, j);
                quoted = true;
                i = j + 1;
            } else if (d === '\\') { delim += src[i + 1] ?? ''; quoted = true; i += 2; } else { delim += d; i++; }
        }
        if (delim) pending.push({ delim, quoted, strip, words }); else ok = false;
    };
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
        else if (c === '\n') { endCmd(c); i++; if (pending.length) bodies(); }
        else if (c === ';' || c === '&' || c === '|') { endCmd(c); i++; }
        else if (c === '<' && src[i + 1] === '<' && src[i + 2] !== '<') heredoc();
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
    // a heredoc whose line never ended: its body cannot be told from what follows
    if (pending.length) ok = false;
    return { cmds, subs, heredocs, ok };
}

/**
 * Whether a whole command line is the one shape whose heredoc body is data (T63g, pm note after R3b): `cat`,
 * one `>` or `>>` to a plain file path, one heredoc, nothing else. A pipe, a list, any substitution, another
 * redirect, or a command after the body: the body is judged as commands.
 */
function heredocToFile(cmds) {
    // a substitution or a second heredoc command shows up as a word that is not plain, or as a second command
    if (cmds.length !== 1) return false;
    const [name, ...rest] = cmds[0];
    const plain = (p) => /^[\w./~+@%,:-]+$/.test(p);
    return name === 'cat' && ((rest.length === 2 && (rest[0] === '>' || rest[0] === '>>') && plain(rest[1]))
        || (rest.length === 1 && /^>>?[^>]/.test(rest[0]) && plain(rest[0].replace(/^>>?/, ''))));
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
 * Whether `path` is part of the push gate (T63g, R3 R1, R3a M2, R3b L1): a git config file the protected
 * repository reads (its own and its worktrees', the user's and the system's), where my-team.* and
 * core.hooksPath live; its hooks folder or anything in it, where the pre-push hook and its copies live; or
 * its git folder itself. Without a protected
 * repository, any repository's counts.
 */
function gateFile(path, protectedRepo) {
    const key = pathKey(path);
    const home = homedir();
    if ([join(home, '.gitconfig'), join(home, '.config', 'git', 'config'), '/etc/gitconfig'].map(pathKey).includes(key)) return true;
    if (!protectedRepo) return /[/\\]\.git([/\\](config(\.worktree)?|hooks([/\\].*)?))?$/s.test(key);
    const common = protectedRepo.common ?? pathKey(join(protectedRepo.root, '.git'));
    const hooks = common + sep + 'hooks';
    // the git folder itself too: moving or removing it takes the hook along (R3b L1)
    return key === common || key === common + sep + 'config' || (key.startsWith(common + sep) && key.endsWith('config.worktree'))
        || key === hooks || key.startsWith(hooks + sep);
}

/** Commands that only read the files they name; any other may write them. */
const FILE_READERS = new Set(['cat', 'head', 'tail', 'less', 'more', 'grep', 'egrep', 'fgrep', 'rg', 'wc', 'diff', 'cmp',
    'stat', 'ls', 'file', 'shasum', 'md5', 'echo', 'printf', 'test', '[']);

/** The gate file a command writes, by a redirect or as a file argument of a command that may write; or null. */
function writtenGateFile(cmd, dir, protectedRepo) {
    const at = (p) => {
        if (!p || unknownWord(p)) return null;
        const full = expandHome(p);
        if (!isAbsolute(full) && dir === null) return null;
        return resolve(dir ?? '/', full);
    };
    const targets = [];
    for (let k = 0; k < cmd.args.length; k++) {
        const m = /^\d*>>?\|?(.*)$/s.exec(cmd.args[k]);
        if (m) targets.push(m[1] || cmd.args[++k]);
        else if (!FILE_READERS.has(cmd.name) && !cmd.args[k].startsWith('-')) targets.push(cmd.args[k]);
    }
    return targets.map(at).find((p) => p !== null && gateFile(p, protectedRepo)) ?? null;
}

/**
 * `git config` options (git-config(1)): those that only read, those taking a value, and those that change
 * neither. Any other (--unset, --add, --replace-all, --rename-section, --remove-section, -e …) is a write.
 */
const CONFIG_READS = new Set(['--get', '--get-all', '--get-regexp', '--get-urlmatch', '--list', '-l', '--get-color', '--get-colorbool']);
const CONFIG_WITH_ARG = new Set(['-f', '--file', '--blob', '--type', '--default', '--comment', '--value']);
const CONFIG_FLAGS = new Set(['--global', '--system', '--local', '--worktree', '--bool', '--int', '--bool-or-int', '--path',
    '--expiry-date', '-z', '--null', '--name-only', '--show-origin', '--show-scope', '--includes', '--no-includes', '--fixed-value', '--all']);
/** git 2.46's subcommand form: `git config get|list|set|unset|…`. */
const CONFIG_SUBCOMMANDS = { get: 'read', list: 'read', set: 'write', unset: 'write', 'rename-section': 'write', 'remove-section': 'write', edit: 'write' };

/**
 * What a `git config` line does: `write` (false only when it certainly only reads: an unknown option or a
 * value from a variable counts as a write), the key or section (null: all of it, or unknown), and where:
 * `scope` local, global, system or file (`file` the path given).
 */
function configCall(rest) {
    let mode = null, scope = 'local', file;
    const pos = [];
    for (let k = 0; k < rest.length; k++) {
        const a = rest[k];
        if (a === '--') { pos.push(...rest.slice(k + 1)); break; }
        if (!a.startsWith('-') || unknownWord(a)) { pos.push(a); continue; }
        const name = a.split('=')[0];
        if (CONFIG_READS.has(name)) mode = 'read';
        else if (name === '--global' || name === '--system') scope = name.slice(2);
        else if (CONFIG_WITH_ARG.has(name)) {
            const value = a.includes('=') ? a.slice(a.indexOf('=') + 1) : rest[++k];
            if (name === '-f' || name === '--file') { scope = 'file'; file = value; }
        } else if (!CONFIG_FLAGS.has(name)) return { write: true, key: null, scope, file };
    }
    if (Object.hasOwn(CONFIG_SUBCOMMANDS, pos[0])) return { write: CONFIG_SUBCOMMANDS[pos[0]] === 'write', key: pos[1] ?? null, scope, file };
    const key = pos[0] ?? null;
    const write = mode === null && (pos.length >= 2 || (key !== null && unknownWord(key)));
    return { write, key: key !== null && unknownWord(key) ? null : key, scope, file };
}

/**
 * `git config` that writes where it reaches the protected repository (T63g, R3 R1): `repo-write` refuses any
 * such write; `push` refuses one of a my-team.* key (the push gate's settings), in the repository's config or
 * the user's or system's, which it reads too.
 */
function configDenial(git, dir, rules, protectedRepo) {
    const c = configCall(git.rest);
    if (!c.write) return null;
    let reaches;
    if (c.scope === 'global' || c.scope === 'system') reaches = 'everywhere';
    else if (c.scope === 'file') {
        const path = c.file === undefined || unknownWord(c.file) ? null : resolve(git.targets[0] ?? dir ?? '/', expandHome(c.file));
        reaches = path === null || (dir === null && !isAbsolute(expandHome(c.file))) || gateFile(path, protectedRepo) || touchesProtected([path], protectedRepo) ? 'repository' : null;
    } else reaches = touchesProtected(git.targets, protectedRepo) ? 'repository' : null;
    if (!reaches) return null;
    if (rules.includes('repo-write') && reaches === 'repository') return { rule: 'repo-write', reason: 'git config writes the protected repository\'s config' };
    // my-team.* sets the gate up; core.hooksPath (or removing its section) moves the pre-push hook away (R3a M2);
    // an included file can set either (R3b R1)
    const gateKey = c.key === null || /^(my-team(\..*)?|core(\.hookspath)?|include(\.path)?|includeif(\..*)?)$/is.test(c.key);
    if (gateKey) return { rule: rules.includes('push') ? 'push' : 'repo-write', reason: `git config ${c.key ?? '<unknown key>'} reaches the push gate's settings or its hook` };
    return null;
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
    const { cmds, subs, heredocs, ok } = lex(command);
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
        if (cmd.name !== 'git') {
            const file = writtenGateFile(cmd, dir, protectedRepo);
            return file ? { rule: rules.includes('push') ? 'push' : 'repo-write', reason: `it writes ${file}, part of the push gate (git config or hooks)` } : null;
        }
        const git = gitCall(cmd.args, cmd.env, dir);
        if (gitEnvUnknown && git.targets) git.targets.push(null);
        if (git.sub === undefined) return { rule: rules[0], reason: 'a git command it cannot read (unknown option, -c alias, or a value from a variable)' };
        if (git.sub === null || git.help) return null;
        if (git.sub === 'config') return configDenial(git, dir, rules, protectedRepo);
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
    // a heredoc body is judged as commands unless the line is `cat > file <<EOF` alone (T63g); as data, an
    // unquoted delimiter still runs the body's substitutions (bash(1), Here Documents)
    const toFile = heredocToFile(cmds);
    for (const h of heredocs) {
        if (!toFile) {
            const found = denial(h.body, rules, moved ? null : start, protectedRepo);
            if (found) return found;
            continue;
        }
        if (h.quoted) continue;
        const inner = substitutionsIn(h.body);
        if (!inner.ok && rules.includes('push') && /\bpush\b/.test(h.body)) return { rule: 'push', reason: 'an unclosed substitution in a heredoc around push' };
        for (const sub of inner.subs) {
            const found = denial(sub, rules, moved ? null : start, protectedRepo);
            if (found) return found;
        }
    }
    return null;
}

/**
 * For an edit of `path` (relative to `cwd`): a gate file (git config or hooks, see gateFile) is refused by
 * either rule (T63g, R3 R1, R3a M2); with `repo-write`, so is anything inside
 * `repoRoot`. Null when the edit may go.
 */
export function pathDenial(path, cwd, repoRoot, rules = ['repo-write']) {
    if (!path) return null;
    const full = isAbsolute(path) ? path : resolve(cwd, path);
    if (rules.includes('push') || rules.includes('repo-write')) {
        const protectedRepo = repoRoot ? { root: repoRoot, common: gitCommonDir(repoRoot) } : null;
        if (gateFile(full, protectedRepo)) return { rule: rules.includes('push') ? 'push' : 'repo-write', reason: `${path} is part of the push gate (git config or hooks)` };
    }
    if (!repoRoot || !rules.includes('repo-write')) return null;
    const target = pathKey(full);
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
