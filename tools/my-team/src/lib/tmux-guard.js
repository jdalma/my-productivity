/**
 * What the tmux shim on a worker's PATH lets through (T56). A tmux call without -L or -S reaches the user's
 * server, where the user's teams live: there only commands that read pass. A call that names a server of
 * its own passes whatever it asks, unless the name is the default server's. Anything the shim cannot tell
 * is refused. A tmux called by absolute path skips the shim: this guards against mistakes, not intent.
 */

import { accessSync, constants, realpathSync, statSync } from 'fs';
import { dirname, join, normalize, resolve } from 'path';
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

function canonical(path) {
    const abs = resolve(path);
    try { return join(realpathSync(dirname(abs)), abs.slice(dirname(abs).length + 1)); } catch { return normalize(abs); }
}

/** The sockets a call without -L/-S may reach: the default one, as TMUX_TMPDIR or its /tmp fallback has it, and $TMUX's. */
function userSockets(env, uid) {
    const dirs = [env.TMUX_TMPDIR, '/tmp'].filter(Boolean);
    const sockets = dirs.map((d) => join(d, `tmux-${uid}`, 'default'));
    const inTmux = (env.TMUX ?? '').split(',')[0];
    if (inTmux) sockets.push(inTmux);
    return new Set(sockets.map(canonical));
}

/** `{ allow }` for a tmux call with `args`, made by a worker whose environment is `env`. */
export function tmuxShimVerdict(args, env = process.env, uid = process.getuid()) {
    const global = getopt(args, 0, GLOBAL_FLAGS, GLOBAL_WITH_ARG);
    if (!global) return { allow: false };
    const { seen, next } = global;
    if (seen.has('V')) return { allow: true };
    const label = seen.get('L'), path = seen.get('S');
    const ownServer = path !== undefined ? path !== '' && !userSockets(env, uid).has(canonical(path))
        : label !== undefined && label !== '' && label !== 'default';
    if (ownServer) return { allow: true };
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

/** The first executable `tmux` on `pathVar` that is not the shim, or null. */
export function findRealTmux(pathVar = process.env.PATH ?? '') {
    const shim = canonical(join(SHIM_DIR, 'tmux'));
    for (const dir of pathVar.split(':')) {
        if (!dir) continue;
        const candidate = join(dir, 'tmux');
        try {
            accessSync(candidate, constants.X_OK);
            if (!statSync(candidate).isFile()) continue;
            if (canonical(realpathSync(candidate)) === shim) continue;
            return candidate;
        } catch { /* not here */ }
    }
    return null;
}
