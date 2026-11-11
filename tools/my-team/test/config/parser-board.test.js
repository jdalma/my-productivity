/**
 * Config `board` item (T63d, rfc/board-design.md §7): its presence makes a team a board team; `store` picks
 * the adapter (sqlite by default, memory for tests). start copies it into the manifest, where the board
 * commands read it.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { validateConfig } from '../../src/config/parser.js';

function check(board) {
    const cwd = mkdtempSync(join(tmpdir(), 'my-team-board-'));
    try {
        return validateConfig({ team_name: 'board-test', workers: [{ name: 'a', agent_type: 'claude', cwd }], ...(board === undefined ? {} : { board }) });
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
}

test('no board item: not a board team', () => {
    assert.equal(check(undefined).board, null);
});

test('a board item: sqlite unless it names memory', () => {
    assert.deepEqual(check({}).board, { store: 'sqlite' });
    assert.deepEqual(check({ store: 'sqlite' }).board, { store: 'sqlite' });
    assert.deepEqual(check({ store: 'memory' }).board, { store: 'memory' });
});

test('a board item that is not an object, names another store or carries other keys is refused', () => {
    for (const bad of [true, 'sqlite', null, [], { store: 'postgres' }, { store: 'sqlite', path: '/x' }]) {
        assert.throws(() => check(bad), /board/, JSON.stringify(bad));
    }
});
