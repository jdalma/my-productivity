/**
 * Config `group` (optional): the team a feature team belongs to. start keeps it in the manifest, and status and
 * Control Tower read it from there.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { validateConfig } from '../../src/config/parser.js';

function check(group) {
    const cwd = mkdtempSync(join(tmpdir(), 'my-team-group-'));
    try {
        return validateConfig({ team_name: 'nudake-payment', workers: [{ name: 'a', agent_type: 'claude', cwd }], ...(group === undefined ? {} : { group }) });
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
}

test('no group: null', () => {
    assert.equal(check(undefined).group, null);
});

test('a group with the characters of a team name is kept', () => {
    assert.equal(check('nudake').group, 'nudake');
    assert.equal(check('shop-api').group, 'shop-api');
});

test('any other group is refused with the rule', () => {
    for (const bad of ['', 'Nudake', 'nu dake', '-x', 'x-', 'a', 7, null, ['nudake']]) {
        assert.throws(() => check(bad), /group must match/, JSON.stringify(bad));
    }
});
