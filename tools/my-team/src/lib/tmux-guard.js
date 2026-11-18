/**
 * What the tmux shim on a worker's PATH lets through (T56). A tmux call without -L or -S reaches the user's
 * server, where the user's teams live: there only commands that read pass. A call that names a server of
 * its own passes whatever it asks, unless the name is the default server's. Anything the shim cannot tell
 * is refused. A tmux called by absolute path skips the shim: this guards against mistakes, not intent.
 */

import { accessSync, constants, readFileSync, realpathSync, statSync } from 'fs';
import { basename, dirname, join, resolve } from 'path';
import { fileURLToPath } from 'url';

export const SHIM_DIR = fileURLToPath(new URL('../../shim', import.meta.url));

/** tmux(1) global options, as tmux 3.6 parses them. */
const GLOBAL_FLAGS = '2CDhlNuVv';
const GLOBAL_WITH_ARG = 'cfLST';

/**
 * Commands that only read, by name and alias, each with its getopt letters (tmux list-commands, 3.6a).
 * `need`: the flag without which the command writes (display-message shows on a client, capture-pane fills
 * a buffer); `deny`: a flag that writes (display-message -I types stdin into a pane).
 */
const READERS = new Map();
for (const [names, flags, withArg, need, deny] of [
    [['list-sessions', 'ls'], '', 'Ff'],
    [['list-windows', 'lsw'], 'a', 'Fft'],
    [['list-panes', 'lsp'], 'as', 'Fft'],
    [['list-clients', 'lsc'], '', 'Fft'],
    [['list-buffers', 'lsb'], '', 'Ff'],
    [['list-keys', 'lsk'], '1aN', 'PT'],
    [['list-commands', 'lscm'], '', 'F'],
    [['has-session', 'has'], '', 't'],
    [['show-options', 'show'], 'AgHpqsvw', 't'],
    [['show-window-options', 'showw'], 'gv', 't'],
    [['show-environment', 'showenv'], 'hgs', 't'],
    [['show-hooks'], 'gpw', 't'],
    [['show-buffer', 'showb'], '', 'b'],
    [['display-message', 'display'], 'aClINpv', 'cdFt', 'p', 'I'],
    [['capture-pane', 'capturep'], 'aCeJMNpPqT', 'bESt', 'p'],
]) for (const n of names) READERS.set(n, { flags, withArg, need, deny });

/** getopt over `args` from `i`: the letters seen and their values, where the operands start, or null on an unknown letter. */
function getopt(args, i, flags, withArg) {
    const seen = new Map();
    for (; i < args.length; i++) {
        const a = args[i];
        if (a === '--') return { seen, next: i + 1 };
        if (!a.startsWith('-') || a === '-') break;
        for (let j = 1; j < a.length; j++) {
            const c = a[j];
            if (withArg.includes(c)) {
                const value = j + 1 < a.length ? a.slice(j + 1) : args[++i];
                if (value === undefined) return null;
                seen.set(c, value);
                break;
            }
            if (!flags.includes(c)) return null;
            seen.set(c, true);
        }
    }
    return { seen, next: i };
}

/**
 * A path as the file system finds it (R57 M1): symlinks followed and names in their stored case, through
 * realpath.native on the path or, while it does not exist yet, on its nearest existing folder. Lowercased
 * as well, so a name that differs only in case is the same file on a case-insensitive volume (APFS, the
 * default) and, on a case-sensitive one, is refused when it would have passed: refusing is the safe side.
 * Sockets here, and the worker guard's repository paths (T59).
 */
export function pathKey(path) {
    let dir = resolve(path);
    const rest = [];
    for (;;) {
        try { return join(realpathSync.native(dir), ...rest).toLowerCase(); } catch { /* not there yet */ }
        const up = dirname(dir);
        if (up === dir) return join(dir, ...rest).toLowerCase();
        rest.unshift(basename(dir));
        dir = up;
    }
}

/** Where tmux looks for `-L` sockets: under TMUX_TMPDIR, or /tmp when that folder is missing. Both, as the shim cannot tell. */
function socketDirs(env, uid) {
    return [env.TMUX_TMPDIR, '/tmp'].filter(Boolean).map((d) => join(d, `tmux-${uid}`));
}

/** A socket file's identity, which a hard link shares (R57a L5); null while there is none. */
function fileId(path) {
    try { const st = statSync(path); return `${st.dev}:${st.ino}`; } catch { return null; }
}

/** The sockets of the user's server: the default one, and $TMUX's, the server the worker is in. */
function userSockets(env, uid) {
    const sockets = socketDirs(env, uid).map((d) => join(d, 'default'));
    const inTmux = (env.TMUX ?? '').split(',')[0];
    if (inTmux) sockets.push(inTmux);
    const keys = new Set(sockets.map(pathKey));
    const ids = new Set(sockets.map(fileId).filter(Boolean));
    return { has: (p) => keys.has(pathKey(p)) || ids.has(fileId(p)) };
}

/** `{ allow }` for a tmux call with `args`, made by a worker whose environment is `env`. */
export function tmuxShimVerdict(args, env = process.env, uid = process.getuid()) {
    const global = getopt(args, 0, GLOBAL_FLAGS, GLOBAL_WITH_ARG);
    if (!global) return { allow: false };
    const { seen, next } = global;
    if (seen.has('V')) return { allow: true };
    const label = seen.get('L'), path = seen.get('S');
    // -S wins over -L in tmux; -L <name> is <dir>/tmux-<uid>/<name>, so `./default` and `DEFAULT` are the default
    const named = path !== undefined ? (path ? [path] : [])
        : label ? socketDirs(env, uid).map((d) => join(d, label)) : [];
    const user = userSockets(env, uid);
    if (named.length > 0 && named.every((p) => !user.has(p))) return { allow: true };
    if (seen.has('C') || seen.has('c')) return { allow: false };

    const rest = args.slice(next);
    if (rest.length === 0 || rest.some((a) => a.endsWith(';'))) return { allow: false };
    const reader = READERS.get(rest[0]);
    if (!reader) return { allow: false };
    const opts = getopt(rest, 1, reader.flags, reader.withArg);
    if (!opts) return { allow: false };
    if (reader.need && !opts.seen.has(reader.need)) return { allow: false };
    if (reader.deny && opts.seen.has(reader.deny)) return { allow: false };
    return { allow: true };
}

/**
 * Whether `path` is a my-team shim, of this copy or any other (R58 M1): a worker started under one copy
 * (the repo, through npm link) keeps that copy's shim on PATH while `my-team` is now another (a deployed
 * one), and that shim would refuse my-team's own send-keys. Every shim is a small script naming tmux-shim.js;
 * tmux is a binary of hundreds of KB.
 */
function isShim(path) {
    const st = statSync(path);
    return st.size < 4096 && readFileSync(path, 'utf-8').includes('tmux-shim.js');
}

/** The first executable `tmux` on `pathVar` that is not a my-team shim, or null. */
export function findRealTmux(pathVar = process.env.PATH ?? '') {
    for (const dir of pathVar.split(':')) {
        if (!dir) continue;
        const candidate = join(dir, 'tmux');
        try {
            accessSync(candidate, constants.X_OK);
            if (!statSync(candidate).isFile() || isShim(candidate)) continue;
            return candidate;
        } catch { /* not here */ }
    }
    return null;
}
