/**
 * `my-team api roster` — read-only lookup of a team's current roster, so an
 * orchestrator can address a team it was pointed at without guessing worker
 * names. The manifest keyed by team name is the registry.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiRoster } from '../../src/commands/api/roster.js';

function setup() {
    const base = mkdtempSync(join(tmpdir(), 'my-team-roster-'));
    const stateRoot = join(base, 'payments');
    mkdirSync(stateRoot, { recursive: true });
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify({
        team_name: 'payments', state_root: stateRoot, session_name: 'my-team-payments-x:0',
        workers: [
            { name: 'pm', pane_id: '%1', cwd: '/tmp/a', agent_type: 'claude', role: 'orchestrator', description: 'payments PM', overlay_path: '' },
            { name: 'dev', pane_id: '%2', cwd: '/tmp/b', agent_type: 'codex', role: 'worker', overlay_path: '' },
        ],
    }));
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return base;
}

function cleanup(base) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    rmSync(base, { recursive: true, force: true });
}

test('roster returns name/agent_type/role/description for the named team only', async () => {
    const base = setup();
    try {
        const res = await runApiRoster({ team_name: 'payments' });
        assert.equal(res.ok, true);
        assert.equal(res.team_name, 'payments');
        assert.deepEqual(res.workers, [
            { name: 'pm', agent_type: 'claude', role: 'orchestrator', description: 'payments PM' },
            { name: 'dev', agent_type: 'codex', role: 'worker', description: '' },
        ]);
        assert.equal(res.workers[0].pane_id, undefined, 'pane ids are the user\'s, not a worker surface');
    } finally {
        cleanup(base);
    }
});

test('roster requires team_name and fails loudly for an unknown team', async () => {
    const base = setup();
    try {
        await assert.rejects(() => runApiRoster({}), /team_name is required/);
        await assert.rejects(() => runApiRoster({ team_name: 'nope' }), /manifest not found/);
    } finally {
        cleanup(base);
    }
});
