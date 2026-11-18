/**
 * State root resolution for my-team.
 *
 * Replaces OMC's `dist/utils/config-dir.js` (`getClaudeConfigDir`). Instead of
 * defaulting to `~/.claude`, my-team uses `~/.my-team/sessions` and honours
 * `MY_TEAM_STATE_ROOT_BASE` as an override.
 *
 * Per-session callers can also call `setStateRoot()` once at startup so that
 * OMC modules which still call `getClaudeConfigDir()` see the same path.
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

/**
 * OMC compatibility shim. The originally-borrowed OMC modules that called this
 * (inbox-outbox, outbox-reader, task-file-ops) have all been removed in the
 * option-B cutover, so this export currently has no in-tree callers. Kept as a
 * one-line forwarder in case a future OMC-borrowed module needs the same
 * config-dir indirection.
 */
export function getClaudeConfigDir() {
    return getStateRootBase();
}
