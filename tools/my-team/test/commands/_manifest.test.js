/**
 * Unit tests for resolveTeamManifest — the shared helper that lets `add-worker`
 * and `shutdown` accept --team as EITHER a team name OR a tmux session name.
 *
 * A session name cannot be parsed back into a team name (both may contain
 * hyphens/digits), so resolution scans manifests under defaultBase() and matches
 * on session_name. These tests cover all three resolution paths and the
 * canonical-team-name guarantee callers depend on.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { resolveTeamManifest } from '../../src/commands/_manifest.js';

/**
 * Build a state base with one or more team dirs, each holding a manifest.json.
 * Points MY_TEAM_STATE_ROOT_BASE at it so defaultBase() (and thus the fallback
 * scan) reads from here. Returns { base, cleanup }.
 */
function setupBase(teams) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-resolve-'));
    for (const t of teams) {
        const dir = join(base, t.team_name);
        mkdirSync(dir, { recursive: true });
        writeFileSync(
            join(dir, 'manifest.json'),
            JSON.stringify({ team_name: t.team_name, session_name: t.session_name, workers: [] }),
            'utf-8'
        );
    }
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return {
        base,
        cleanup() {
            delete process.env.MY_TEAM_STATE_ROOT_BASE;
            rmSync(base, { recursive: true, force: true });
        },
    };
}

test('resolves by team name (fast path)', () => {
    const ctx = setupBase([{ team_name: 'alpha', session_name: 'my-team-alpha-abc123:0' }]);
    try {
        const { manifest, teamName } = resolveTeamManifest('alpha', undefined);
        assert.equal(teamName, 'alpha');
        assert.equal(manifest.session_name, 'my-team-alpha-abc123:0');
    } finally { ctx.cleanup(); }
});

test('resolves by tmux session name (no :window suffix, as tmux ls shows it)', () => {
    const ctx = setupBase([{ team_name: 'alpha', session_name: 'my-team-alpha-abc123:0' }]);
    try {
        // tmux ls shows the name WITHOUT the :0 window suffix.
        const { teamName } = resolveTeamManifest('my-team-alpha-abc123', undefined);
        assert.equal(teamName, 'alpha', 'session name resolves to canonical team name');
    } finally { ctx.cleanup(); }
});

test('resolves by session name WITH :window suffix too', () => {
    const ctx = setupBase([{ team_name: 'alpha', session_name: 'my-team-alpha-abc123:0' }]);
    try {
        const { teamName } = resolveTeamManifest('my-team-alpha-abc123:0', undefined);
        assert.equal(teamName, 'alpha');
    } finally { ctx.cleanup(); }
});

test('disambiguates teams whose names share a hyphenated prefix', () => {
    // 'demo-team' and 'demo-team-2' both exist; a session name must map to
    // exactly the right one — proof that we match on session_name, not parse.
    const ctx = setupBase([
        { team_name: 'demo-team', session_name: 'my-team-demo-team-aaa:0' },
        { team_name: 'demo-team-2', session_name: 'my-team-demo-team-2-bbb:0' },
    ]);
    try {
        assert.equal(resolveTeamManifest('my-team-demo-team-2-bbb', undefined).teamName, 'demo-team-2');
        assert.equal(resolveTeamManifest('my-team-demo-team-aaa', undefined).teamName, 'demo-team');
    } finally { ctx.cleanup(); }
});

test('a broken manifest in the scan does not abort resolution of others', () => {
    const ctx = setupBase([{ team_name: 'good', session_name: 'my-team-good-zzz:0' }]);
    try {
        // Drop a sibling dir with unparseable JSON; the scan must skip it.
        const brokenDir = join(ctx.base, 'broken');
        mkdirSync(brokenDir, { recursive: true });
        writeFileSync(join(brokenDir, 'manifest.json'), '{ not valid json', 'utf-8');

        const { teamName } = resolveTeamManifest('my-team-good-zzz', undefined);
        assert.equal(teamName, 'good');
    } finally { ctx.cleanup(); }
});

test('throws a clear error when nothing matches', () => {
    const ctx = setupBase([{ team_name: 'alpha', session_name: 'my-team-alpha-abc123:0' }]);
    try {
        assert.throws(
            () => resolveTeamManifest('my-team-nope-deadbeef', undefined),
            /No team matched|running/i
        );
    } finally { ctx.cleanup(); }
});

test('--state-root bypasses the scan and still returns canonical team name', () => {
    const base = mkdtempSync(join(tmpdir(), 'my-team-resolve-sr-'));
    const stateRoot = join(base, 'whatever-dir'); // dir name need not equal team_name
    mkdirSync(stateRoot, { recursive: true });
    writeFileSync(
        join(stateRoot, 'manifest.json'),
        JSON.stringify({ team_name: 'realname', session_name: 'my-team-realname-x:0', workers: [] }),
        'utf-8'
    );
    try {
        const { teamName } = resolveTeamManifest('anything', stateRoot);
        assert.equal(teamName, 'realname', 'canonical team name comes from the manifest, not the input');
    } finally {
        rmSync(base, { recursive: true, force: true });
    }
});
