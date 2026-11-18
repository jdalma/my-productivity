/**
 * Shared validation helpers for v2 mailbox API handlers.
 *
 * Hardens the boundary against:
 *   - path traversal via the `worker` field (untrusted input → fs paths)
 *   - inconsistent schema_version handling between read paths
 */

import { sanitizeName, validateTeamName } from './team-name.js';
import { validateResolvedPath } from './fs-utils.js';
import { TeamPaths, absPath } from './state-paths.js';
import { MAILBOX_SCHEMA_VERSION } from './tmux-comm.js';

/**
 * Validate team_name + worker arguments and return a sanitized pair safe to
 * compose into filesystem paths. Throws when either value is missing or
 * fails the sanitizer.
 */
export function requireTeamAndWorker(input, opts = {}) {
    const { workerKey = 'worker' } = opts;
    const teamName = input?.team_name;
    const worker = input?.[workerKey];
    if (!teamName) throw new Error('team_name is required');
    if (!worker) throw new Error(`${workerKey} is required`);
    validateTeamName(teamName);
    const safeWorker = sanitizeName(worker);
    return { teamName, worker: safeWorker };
}

/**
 * Resolve a per-cwd path under the team root, verifying it stays inside the
 * team's state directory. Use for every mailbox/archive/spool path that is
 * derived from untrusted input.
 */
export function resolveTeamPath(teamName, worker, cwd, pathFn) {
    const rootAbs = absPath(cwd, TeamPaths.root(teamName));
    const targetAbs = absPath(cwd, pathFn(teamName, worker));
    validateResolvedPath(targetAbs, rootAbs);
    return targetAbs;
}

/**
 * Validate a parsed mailbox object's schema_version. Treats both
 * "mismatched" and "missing" as fatal — there is no automatic migration.
 *
 * Returns the parsed object unchanged when valid so callers can chain.
 */
export function assertMailboxSchemaVersion(parsed, filePath) {
    if (!parsed || typeof parsed !== 'object') return parsed;
    if (parsed.schema_version !== MAILBOX_SCHEMA_VERSION) {
        throw new Error(
            `Mailbox at ${filePath} has schema_version=${parsed.schema_version ?? 'missing'}, ` +
            `expected ${MAILBOX_SCHEMA_VERSION}. ` +
            `Shutdown the team (my-team shutdown) and restart to begin with a fresh schema; ` +
            `automatic migration is not supported.`
        );
    }
    return parsed;
}
