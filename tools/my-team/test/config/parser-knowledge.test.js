/**
 * Config `knowledge` (T68): a team's shared documents, each {path, about}. The path is absolute or under ~;
 * about is one line. A missing file is a warning at start, not an error. Example paths only.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'fs';
import { homedir, tmpdir } from 'os';
import { join } from 'path';

import { missingKnowledge, validateConfig } from '../../src/config/parser.js';

function check(knowledge) {
    const cwd = mkdtempSync(join(tmpdir(), 'my-team-knowledge-'));
    try {
        return validateConfig({ team_name: 'k-test', workers: [{ name: 'a', agent_type: 'claude', cwd }], ...(knowledge === undefined ? {} : { knowledge }) });
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
}

test('no knowledge item: null', () => {
    assert.equal(check(undefined).knowledge, null);
});

test('a knowledge list: paths kept absolute, ~ expanded, about kept', () => {
    assert.deepEqual(check([
        { path: '/docs/example.com/guide.md', about: 'how lookups work' },
        { path: '~/notes/example.md', about: 'naming rules' },
    ]).knowledge, [
        { path: '/docs/example.com/guide.md', about: 'how lookups work' },
        { path: join(homedir(), 'notes/example.md'), about: 'naming rules' },
    ]);
});

test('(d) a knowledge item of the wrong shape, a relative path, or an about on several lines is refused', () => {
    for (const bad of [
        'docs.md', {}, [{ path: '/a.md' }], [{ about: 'x' }], [{ path: 'docs/a.md', about: 'x' }], [{ path: './a.md', about: 'x' }],
        [{ path: '/a.md', about: '' }], [{ path: '/a.md', about: 'one\ntwo' }], [{ path: '/a.md', about: 'x', body: 'y' }], ['/a.md'],
    ]) {
        assert.throws(() => check(bad), /knowledge/, JSON.stringify(bad));
    }
});

test('(d) missingKnowledge names the documents that are not there; start warns with it and goes on', (t) => {
    const dir = mkdtempSync(join(tmpdir(), 'my-team-knowledge-files-'));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    writeFileSync(join(dir, 'here.md'), 'x');
    const knowledge = [{ path: join(dir, 'here.md'), about: 'a' }, { path: join(dir, 'gone.md'), about: 'b' }];
    assert.deepEqual(missingKnowledge(knowledge), [join(dir, 'gone.md')]);
    assert.deepEqual(missingKnowledge(null), []);
});
