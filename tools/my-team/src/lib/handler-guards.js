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
 *
 * A worker process acts only as itself (T7, T58's rule): with MY_TEAM_WORKER
 * (`<team>/<worker>`, set by start and add-worker) the input must name that
 * team and worker, so it cannot absorb another worker's spool or consume its
 * mail. Without the variable (the user's shell) the input stands. Catches
 * mistakes, not intent: a process can run with the variable changed.
 */
export function requireTeamAndWorker(input, opts = {}) {
    const { workerKey = 'worker', env = process.env } = opts;
    const teamName = input?.team_name;
    const worker = input?.[workerKey];
    if (!teamName) throw new Error('team_name is required');
    if (!worker) throw new Error(`${workerKey} is required`);
    validateTeamName(teamName);
    const safeWorker = sanitizeName(worker);
    const pinned = env.MY_TEAM_WORKER;
    if (pinned) {
        const slash = pinned.indexOf('/');
        const pinnedTeam = pinned.slice(0, slash), pinnedWorker = pinned.slice(slash + 1);
        if (pinnedTeam !== teamName) {
            throw forbidden(`This process is worker '${pinnedWorker}' of team '${pinnedTeam}' (MY_TEAM_WORKER=${pinned}), not of '${teamName}'`);
        }
        if (safeWorker !== sanitizeName(pinnedWorker)) {
            throw forbidden(`This process was started as '${pinnedWorker}' (MY_TEAM_WORKER=${pinned}); use ${workerKey} "${pinnedWorker}"`);
        }
    }
    return { teamName, worker: safeWorker };
}

function forbidden(message) {
    return Object.assign(new Error(message), { code: 'forbidden' });
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
