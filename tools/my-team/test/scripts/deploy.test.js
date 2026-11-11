/**
 * scripts/deploy.sh installs a commit, not the working tree (T57): what is installed stays as it was while
 * the repo changes, until the next deploy. Run on a clone of this repo and into a prefix of the test's own;
 * the global install is never touched.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'child_process';
import { accessSync, constants, cpSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

const HERE = fileURLToPath(new URL('../..', import.meta.url));
const LIMIT = { encoding: 'utf-8', timeout: 120000 };

test('deploy installs the commit, keeps it while the repo changes, and the next deploy brings the new one', (t) => {
    const dir = mkdtempSync(join(tmpdir(), 'mt-deploy-'));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const top = execFileSync('git', ['-C', HERE, 'rev-parse', '--show-toplevel'], LIMIT).trim();
    const repo = join(dir, 'repo');
    execFileSync('git', ['clone', '-q', '--depth', '1', `file://${top}`, repo], LIMIT);
    // the clone gets this checkout's my-team as one commit, so the test runs what is being tested
    const pkg = join(repo, 'tools', 'my-team');
    for (const p of ['bin', 'shim', 'scripts', 'src', 'package.json']) cpSync(join(HERE, p), join(pkg, p), { recursive: true });
    const git = (...args) => execFileSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@t', ...args], LIMIT).trim();
    git('add', '-A'); git('commit', '-q', '--allow-empty', '-m', 'under test');

    const prefix = join(dir, 'prefix');
    const deploy = () => execFileSync('sh', [join(pkg, 'scripts', 'deploy.sh'), '--prefix', prefix], LIMIT);
    const installed = join(prefix, 'lib', 'node_modules', 'my-team');
    const version = () => execFileSync(join(prefix, 'bin', 'my-team'), ['--version'], LIMIT).trim();

    deploy();
    const first = git('rev-parse', 'HEAD');
    assert.equal(version(), `0.1.0 (${first.slice(0, 12)})`, '(a) it runs and names its commit');
    assert.equal(readFileSync(join(installed, 'COMMIT'), 'utf-8').trim(), first);

    const shim = join(installed, 'shim', 'tmux');
    accessSync(shim, constants.X_OK);
    assert.match(execFileSync(shim, ['-V'], LIMIT), /^tmux /, '(d) the installed shim runs');
    const shimDir = execFileSync(process.execPath, ['--input-type=module', '-e',
        `import(${JSON.stringify(join(installed, 'src', 'lib', 'tmux-guard.js'))}).then((m) => console.log(m.SHIM_DIR))`], LIMIT).trim();
    assert.equal(shimDir, join(realpathSync(installed), 'shim'), 'workers get the installed copy\'s shim, not the repo\'s');

    // an uncommitted change: nothing installed changes, and a deploy now still installs the commit (b, e)
    const pj = join(pkg, 'package.json');
    writeFileSync(pj, readFileSync(pj, 'utf-8').replace('"version": "0.1.0"', '"version": "9.9.9"'));
    assert.equal(version(), `0.1.0 (${first.slice(0, 12)})`, '(b) uncommitted');
    deploy();
    assert.equal(version(), `0.1.0 (${first.slice(0, 12)})`, '(e) the deploy took the commit, not the tree');

    // committed: still nothing until the next deploy (b), which brings it (c)
    git('commit', '-q', '-am', 'bump');
    const second = git('rev-parse', 'HEAD');
    assert.equal(version(), `0.1.0 (${first.slice(0, 12)})`, '(b) committed');
    deploy();
    assert.equal(version(), `9.9.9 (${second.slice(0, 12)})`, '(c) redeployed');
});
