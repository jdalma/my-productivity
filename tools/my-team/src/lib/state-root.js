/**
 * State root resolution for my-team.
 *
 * Defaults to `~/.my-team/sessions` and honours `MY_TEAM_STATE_ROOT_BASE` as
 * an override. Per-session callers call `setStateRoot()` once at startup.
 */

import { homedir } from 'os';
import { isAbsolute, join, normalize } from 'path';

let _stateRoot = null;

function expandTilde(p) {
    if (!p) return p;
    if (p === '~') return homedir();
    if (p.startsWith('~/') || p.startsWith('~\\')) return join(homedir(), p.slice(2));
    return p;
}

/** Set the state root for the current process. Should be called once at start. */
export function setStateRoot(path) {
    if (!path) {
        _stateRoot = null;
        return;
    }
    const expanded = expandTilde(path);
    if (!isAbsolute(expanded)) {
        throw new Error(`state_root must be an absolute path or start with "~". Got: "${path}"`);
    }
    _stateRoot = normalize(expanded);
}

/** Default base directory for sessions. */
export function getStateRootBase() {
    if (_stateRoot) return _stateRoot;
    const override = process.env.MY_TEAM_STATE_ROOT_BASE?.trim();
    if (override) return normalize(expandTilde(override));
    return normalize(join(homedir(), '.my-team', 'sessions'));
}

