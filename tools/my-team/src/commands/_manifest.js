/**
 * Helper to locate and load a team manifest by team name.
 * Tries env MY_TEAM_STATE_ROOT_BASE, then ~/.my-team/sessions/<team>.
 */

import { readFileSync, existsSync, readdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

function defaultBase() {
    return process.env.MY_TEAM_STATE_ROOT_BASE?.trim() || join(homedir(), '.my-team', 'sessions');
}

/**
 * A tmux session name carries an optional `:<window>` suffix (manifests store
 * `my-team-<team>-<suffix>:0`, while `tmux ls` shows it without `:0`). Strip it
 * so the two forms compare equal. `:` never appears in a team or session name,
 * so a plain split on the first `:` is safe.
 */
function stripWindowSuffix(name) {
    return typeof name === 'string' ? name.split(':')[0] : name;
}

/**
 * The roster as workers may see it: identity + role text only. Pane ids and
 * paths stay out — they are the user's monitoring surface, not a peer channel.
 */
export function rosterOf(manifest) {
    return (manifest.workers ?? []).map((w) => ({
        name: w.name,
        agent_type: w.agent_type,
        role: w.role ?? null,
        description: w.description ?? '',
    }));
}

export function manifestPathForTeam(teamName, stateRoot) {
    if (stateRoot) return join(stateRoot, 'manifest.json');
    return join(defaultBase(), teamName, 'manifest.json');
}

export function loadManifest(teamName, stateRoot) {
    const p = manifestPathForTeam(teamName, stateRoot);
    if (!existsSync(p)) {
        throw new Error(`Team '${teamName}' manifest not found at ${p}. Is the team running?`);
    }
    try {
        return JSON.parse(readFileSync(p, 'utf-8'));
    } catch (err) {
        throw new Error(`Cannot parse manifest at ${p}: ${err.message}`);
    }
}

/**
 * Resolve a team manifest from EITHER a team name OR a tmux session name.
 *
 * Callers let users pass `--team` as the team name (the state dir name, e.g.
 * `demo-project`) or as the tmux session name shown by `tmux ls`
 * (`my-team-demo-project-mpzgst8p`, with or without a trailing `:0`). A
 * session name cannot be parsed back into a team name — both team names and the
 * base36 suffix may contain hyphens and digits, so the boundary is ambiguous.
 * The only safe mapping is the manifest itself, so:
 *   1. with --state-root: load that manifest directly (no scan).
 *   2. otherwise try the value as a team name (the existing fast path).
 *   3. otherwise scan every manifest under defaultBase() and match the input
 *      against each manifest's session_name (window suffix stripped).
 *
 * Returns { manifest, teamName } where teamName is the CANONICAL team name from
 * the manifest — callers MUST adopt it so downstream path/env/reload logic keys
 * off the real team name, not the session-name input.
 */
export function resolveTeamManifest(teamOrSession, stateRoot) {
    if (stateRoot) {
        const manifest = loadManifest(teamOrSession, stateRoot);
        return { manifest, teamName: manifest.team_name };
    }

    // Fast path: the value is already a team name (state dir exists).
    const directPath = manifestPathForTeam(teamOrSession, undefined);
    if (existsSync(directPath)) {
        const manifest = loadManifest(teamOrSession, undefined);
        return { manifest, teamName: manifest.team_name };
    }

    // Fallback: treat the value as a tmux session name and scan manifests.
    const base = defaultBase();
    const target = stripWindowSuffix(teamOrSession);
    let dirs = [];
    try {
        dirs = readdirSync(base, { withFileTypes: true })
            .filter((d) => d.isDirectory())
            .map((d) => d.name);
    } catch {
        dirs = [];
    }
    for (const dir of dirs) {
        const p = join(base, dir, 'manifest.json');
        if (!existsSync(p)) continue;
        let manifest;
        try {
            manifest = JSON.parse(readFileSync(p, 'utf-8'));
        } catch {
            continue; // a broken manifest must not abort the whole scan
        }
        if (stripWindowSuffix(manifest.session_name) === target) {
            return { manifest, teamName: manifest.team_name };
        }
    }

    throw new Error(
        `No team matched '${teamOrSession}' (tried team dir ${directPath}, then ` +
        `scanned session names under ${base}). Is the team running? Use the team ` +
        `name or the 'tmux ls' session name.`
    );
}
