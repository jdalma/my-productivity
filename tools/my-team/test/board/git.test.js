/**
 * The board's git port (T63e, rfc/board-design.md §2.2, §6.1): what land checks in the assignee's repository —
 * the commits exist, base is an ancestor of commit, the commits between them, the repository's top level.
 * On a scratch repository.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'child_process';
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { gitRange, toplevel } from '../../src/board/git.js';

function repo(t) {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'mt-board-git-')));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { encoding: 'utf-8' }).trim();
    git('init', '-q', '-b', 'main');
    const commit = (name) => { writeFileSync(join(dir, name), name); git('add', name); git('commit', '-q', '-m', name); return git('rev-parse', 'HEAD'); };
    return { dir, git, commit };
}

test('range: base an ancestor gives the commits after it, newest first', async (t) => {
    const r = repo(t);
    const a = r.commit('a'), b = r.commit('b'), c = r.commit('c');
    assert.deepEqual(await gitRange.range(r.dir, a, c), { ancestor: true, commits: [c, b] });
    assert.deepEqual(await gitRange.range(r.dir, c, c), { ancestor: true, commits: [] });
});

test('range: a base that is not an ancestor says so', async (t) => {
    const r = repo(t);
    const a = r.commit('a');
    const b = r.commit('b');
    r.git('checkout', '-q', '-b', 'side', a);
    const s = r.commit('s');
    assert.deepEqual(await gitRange.range(r.dir, b, s), { ancestor: false, commits: [] });
});

test('range: a commit the repository does not have, or a folder that is no repository, is invalid', async (t) => {
    const r = repo(t);
    const a = r.commit('a');
    await assert.rejects(gitRange.range(r.dir, a, 'f'.repeat(40)), (e) => e.code === 'invalid' && /no commit/.test(e.message));
    await assert.rejects(gitRange.range(r.dir, 'e'.repeat(40), a), (e) => e.code === 'invalid');
    const plain = realpathSync(mkdtempSync(join(tmpdir(), 'mt-board-nogit-')));
    t.after(() => rmSync(plain, { recursive: true, force: true }));
    await assert.rejects(gitRange.range(plain, a, a), (e) => e.code === 'invalid');
});

test('toplevel: the repository root of a folder inside it; a folder outside any repository is invalid', (t) => {
    const r = repo(t);
    mkdirSync(join(r.dir, 'sub', 'deep'), { recursive: true });
    assert.equal(toplevel(join(r.dir, 'sub', 'deep')), r.dir);
    const plain = realpathSync(mkdtempSync(join(tmpdir(), 'mt-board-nogit-')));
    t.after(() => rmSync(plain, { recursive: true, force: true }));
    assert.throws(() => toplevel(plain), (e) => e.code === 'invalid');
});

test('a GIT_DIR in the environment does not send the checks to another repository', async (t) => {
    const r = repo(t), other = repo(t);
    const a = r.commit('a'), b = r.commit('b');
    other.commit('x');
    const saved = process.env.GIT_DIR;
    process.env.GIT_DIR = join(other.dir, '.git');
    t.after(() => { if (saved === undefined) delete process.env.GIT_DIR; else process.env.GIT_DIR = saved; });
    assert.deepEqual(await gitRange.range(r.dir, a, b), { ancestor: true, commits: [b] });
    assert.equal(toplevel(r.dir), r.dir);
});
