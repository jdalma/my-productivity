/**
 * `my-team start --detached / --new-window` (T5): the flags reach the config start hands to createTeamSession.
 * A flag only turns its mode on; without it the config file's value stands.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { resolveConfig } from '../../src/commands/start.js';

function configFile(extra) {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'my-team-start-flags-')));
    const path = join(dir, 'team.json');
    writeFileSync(path, JSON.stringify({
        team_name: 'flags', state_root: join(dir, 'state'),
        workers: [{ name: 'a', agent_type: 'claude', cwd: dir }], ...extra,
    }));
    return { dir, path };
}

test('--detached and --new-window turn the modes on over a config that leaves them off', () => {
    const { dir, path } = configFile({});
    try {
        const plain = resolveConfig({ config: path }, dir);
        assert.deepEqual([plain.detached, plain.new_window], [false, false]);
        const flagged = resolveConfig({ config: path, detached: true, newWindow: true }, dir);
        assert.deepEqual([flagged.detached, flagged.new_window], [true, true]);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test('without the flags the config file decides', () => {
    const { dir, path } = configFile({ detached: true, new_window: true });
    try {
        const cfg = resolveConfig({ config: path }, dir);
        assert.deepEqual([cfg.detached, cfg.new_window], [true, true]);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});

test('inline --worker mode takes the flags too', () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'my-team-start-flags-')));
    try {
        const cfg = resolveConfig({ name: 'inline', worker: [`a:claude:${dir}`], detached: true }, dir);
        assert.equal(cfg.detached, true);
        assert.equal(cfg.new_window, false);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
});
