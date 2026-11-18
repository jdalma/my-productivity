/**
 * `my-team api roster` — read a team's current roster by team name.
 *
 * Pure: reads the manifest and nothing else. The manifest keyed by team name
 * (~/.my-team/sessions/<team>/manifest.json) is the registry `to_team`
 * delivery already uses; this exposes the same list so an orchestrator that
 * was pointed at another team can learn its worker names and roles before
 * sending. Liveness is not checked here — send-message fails loudly on a dead
 * team anyway.
 */

import { loadManifest, rosterOf } from '../_manifest.js';

export async function runApiRoster(input) {
    const teamName = input?.team_name;
    if (!teamName) throw new Error('team_name is required');
    const manifest = loadManifest(teamName);
    return { ok: true, team_name: manifest.team_name, workers: rosterOf(manifest) };
}
