/**
 * Config `role` field tests.
 *
 * Rules under test (validateConfig):
 *  - role must be 'orchestrator' | 'worker' when present
 *  - no roles anywhere → legacy peer mode (all null)
 *  - any role present → undeclared workers default to 'worker'
 *  - any role present → at least one orchestrator required
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { validateConfig } from '../../src/config/parser.js';

function withCwd(fn) {
    const cwd = mkdtempSync(join(tmpdir(), 'my-team-role-'));
    try {
        return fn(cwd);
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
}

function cfg(cwd, workers) {
    return {
        team_name: 'role-test',
        workers: workers.map((w) => ({ agent_type: 'claude', cwd, ...w })),
    };
}

test('no roles anywhere → legacy peer mode, role null on every worker', () => {
    withCwd((cwd) => {
        const c = validateConfig(cfg(cwd, [{ name: 'a' }, { name: 'b' }]));
        assert.deepEqual(c.workers.map((w) => w.role), [null, null]);
    });
});

test('any role present → undeclared workers default to worker', () => {
    withCwd((cwd) => {
        const c = validateConfig(cfg(cwd, [
            { name: 'pm', role: 'orchestrator' },
            { name: 'dev' },
        ]));
        assert.deepEqual(c.workers.map((w) => w.role), ['orchestrator', 'worker']);
    });
});

test('roles without any orchestrator are rejected', () => {
    withCwd((cwd) => {
        assert.throws(
            () => validateConfig(cfg(cwd, [{ name: 'a', role: 'worker' }, { name: 'b' }])),
            /no 'orchestrator'/
        );
    });
});

test('multiple orchestrators are allowed (two-hub team)', () => {
    withCwd((cwd) => {
        const c = validateConfig(cfg(cwd, [
            { name: 'pm', role: 'orchestrator' },
            { name: 'dev', role: 'orchestrator' },
            { name: 'helper' },
        ]));
        assert.deepEqual(c.workers.map((w) => w.role), ['orchestrator', 'orchestrator', 'worker']);
    });
});

test('invalid role value is rejected', () => {
    withCwd((cwd) => {
        assert.throws(
            () => validateConfig(cfg(cwd, [{ name: 'a', role: 'leader' }])),
            /role must be one of orchestrator\|worker/
        );
    });
});
