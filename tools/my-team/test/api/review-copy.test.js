/**
 * `my-team api review-copy` (T51): a submitted commit's files in a temporary folder of its own, for a rerun that
 * touches no working tree.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { runApiReviewCopy } from '../../src/commands/api/review-copy.js';

const BIN = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'bin', 'my-team');

function git(repo, ...args) {
    return execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'commit.gpgsign=false', ...args],
        { encoding: 'utf-8' }).trim();
}

/** A repository with two commits: `first` has a.txt "one"; `second` has a.txt "two" and a package in pkg/. */
function repository(t) {
    const repo = realpathSync(mkdtempSync(join(tmpdir(), 'my-team-review-copy-test-')));
    const made = [repo];
    t.after(() => made.forEach((p) => rmSync(p, { recursive: true, force: true })));
    git(repo, 'init', '-q');
    writeFileSync(join(repo, 'a.txt'), 'one\n');
    git(repo, 'add', '.');
    git(repo, 'commit', '-q', '-m', 'first');
    const first = git(repo, 'rev-parse', 'HEAD');
    writeFileSync(join(repo, 'a.txt'), 'two\n');
    mkdirSync(join(repo, 'pkg'));
    writeFileSync(join(repo, 'pkg', 'package.json'), JSON.stringify({ name: 'pkg', version: '1.0.0' }));
    writeFileSync(join(repo, 'pkg', 'package-lock.json'), JSON.stringify({
        name: 'pkg', version: '1.0.0', lockfileVersion: 3, requires: true, packages: { '': { name: 'pkg', version: '1.0.0' } },
    }));
    git(repo, 'add', '.');
    git(repo, 'commit', '-q', '-m', 'second');
    return { repo, first, second: git(repo, 'rev-parse', 'HEAD'), made };
}

test('the copy holds the commit\'s files, not the working tree\'s, and has no .git', (t) => {
    const { repo, second, made } = repository(t);
    writeFileSync(join(repo, 'a.txt'), 'not committed\n');
    const r = runApiReviewCopy({ commit: 'HEAD', repo });
    made.push(r.path);
    assert.equal(r.commit, second);
    assert.equal(readFileSync(join(r.path, 'a.txt'), 'utf-8'), 'two\n');
    assert.equal(r.git, false);
    assert.equal(existsSync(join(r.path, '.git')), false);
    assert.match(r.note, /no \.git/);
    assert.ok(!r.path.startsWith(repo), 'outside the repository');
    assert.deepEqual(r.installable, ['pkg']);
    assert.deepEqual(r.installed, []);
    assert.equal(existsSync(`${r.path}.tar`), false);
    assert.equal(readFileSync(join(repo, 'a.txt'), 'utf-8'), 'not committed\n', 'the working tree is as it was');
});

test('each call makes a folder of its own, of the commit asked', (t) => {
    const { repo, first, made } = repository(t);
    const a = runApiReviewCopy({ commit: first.slice(0, 7), repo });
    const b = runApiReviewCopy({ commit: first, repo });
    made.push(a.path, b.path);
    assert.notEqual(a.path, b.path);
    assert.equal(readFileSync(join(a.path, 'a.txt'), 'utf-8'), 'one\n');
    assert.deepEqual(a.installable, []);
});

test('install runs npm ci in the folders asked, and refuses one with no package-lock.json before copying', (t) => {
    const { repo, made } = repository(t);
    const all = runApiReviewCopy({ commit: 'HEAD', repo, install: true });
    made.push(all.path);
    assert.deepEqual(all.installed, ['pkg']);
    const one = runApiReviewCopy({ commit: 'HEAD', repo, install: ['pkg/'] });
    made.push(one.path);
    assert.deepEqual(one.installed, ['pkg']);
    assert.throws(() => runApiReviewCopy({ commit: 'HEAD', repo, install: ['../elsewhere'] }), { code: 'invalid' });
    assert.throws(() => runApiReviewCopy({ commit: 'HEAD', repo, install: ['nope'] }), { code: 'invalid', message: /it has: pkg/ });
});

test('R48 L1: a failed npm ci names its cause, not the usage text after it', (t) => {
    const { repo } = repository(t);
    writeFileSync(join(repo, 'pkg', 'package-lock.json'), 'not json');
    git(repo, 'commit', '-q', '-am', 'broken lock');
    assert.throws(() => runApiReviewCopy({ commit: 'HEAD', repo, install: true }),
        (err) => err.code === 'invalid' && /npm ci failed in [\s\S]*can only install with an existing package-lock\.json/.test(err.message)
            && !/Usage:|A complete log/.test(err.message));
});

test('a commit that is not there, or none, is refused', (t) => {
    const { repo } = repository(t);
    assert.throws(() => runApiReviewCopy({ commit: 'abc1234', repo }), { code: 'invalid' });
    assert.throws(() => runApiReviewCopy({ repo }), { code: 'invalid' });
});

test('the CLI prints the folder as JSON', (t) => {
    const { repo, second, made } = repository(t);
    const out = JSON.parse(execFileSync('node', [BIN, 'api', 'review-copy', '--input', JSON.stringify({ commit: second }), '--json'],
        { cwd: repo, encoding: 'utf-8' }));
    made.push(out.path);
    assert.equal(out.ok, true);
    assert.equal(out.repo, repo);
    assert.equal(readFileSync(join(out.path, 'a.txt'), 'utf-8'), 'two\n');
});
