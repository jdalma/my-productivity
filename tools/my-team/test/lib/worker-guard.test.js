/**
 * Per-worker deny rules as a Claude Code PreToolUse hook (T59): `push` refuses a Bash command that runs
 * git push, `repo-write` refuses edits inside the worker's git repository and git commands that change it.
 * The hook sees the command string only; a script that pushes is not seen.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { bashDenial, guardLaunch, hookCommand, pathDenial } from '../../src/lib/worker-guard.js';
import { validateConfig } from '../../src/config/parser.js';

const HOOK = fileURLToPath(new URL('../../src/worker-guard-hook.js', import.meta.url));

test('push: every form that runs git push is refused, mentions of it are not (a)', () => {
    const push = (cmd) => bashDenial(cmd, ['push'])?.rule ?? null;
    for (const cmd of [
        'git push', 'git -C x push', 'cd x && git push origin main', 'git status; git push', 'git status\ngit push',
        'git push 2>&1 | tail -3', 'GIT_TRACE=1 git push', 'env A=1 git push', 'command git push', '/usr/bin/git push',
        'git --no-pager push', 'git -c core.x=1 push', 'git -c alias.p=push p', 'git --frobnicate push',
        'bash -c "git push"', "sh -lc 'git push'", 'eval "git push"', 'echo $(git push)', 'echo "$(git push)"',
        'echo `git push`', '(git push)', '{ git push; }', 'nohup git push &', 'time git push --dry-run',
        'if true; then git push; fi', 'echo x | xargs git push', 'git push "unterminated',
    ]) assert.equal(push(cmd), 'push', cmd);
    for (const cmd of [
        'git status', 'git log --grep push', 'echo "git push"', "echo 'git push'", 'grep -rn "git push" .',
        'git commit -m "push later"', 'git pushx', 'ls # git push', 'npm run push',
    ]) assert.equal(push(cmd), null, cmd);
});

test('repo-write: git commands that change the repository are refused; reading ones pass', () => {
    const w = (cmd) => bashDenial(cmd, ['repo-write'])?.rule ?? null;
    for (const cmd of ['git commit -m x', 'git add .', 'git stash', 'git checkout main', 'git reset --hard',
        'git -C /elsewhere commit -m x', 'git restore f', 'git switch b', 'git rm f', 'git mv a b', 'git merge b',
        'git rebase main', 'git cherry-pick abc', 'git revert abc', 'git pull', 'git clean -fd', 'git apply p.diff', 'git am p'])
        assert.equal(w(cmd), 'repo-write', cmd);
    for (const cmd of ['git status', 'git diff', 'git log -3', 'git show HEAD', 'git push'])
        assert.equal(w(cmd), null, cmd);
    assert.equal(bashDenial('git push', ['push', 'repo-write'])?.rule, 'push');
});

function repo(t) {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'mt-guard-')));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const root = join(dir, 'repo');
    mkdirSync(join(root, 'src'), { recursive: true });
    execFileSync('git', ['init', '-q', root]);
    mkdirSync(join(dir, 'outside'));
    return { dir, root };
}

test('repo-write: an edit inside the repository is refused, outside it passes (b)', (t) => {
    const { dir, root } = repo(t);
    symlinkSync(join(root, 'src'), join(dir, 'link'));
    const deny = (path, cwd = dir) => pathDenial(path, cwd, root)?.rule ?? null;
    assert.equal(deny(join(root, 'src', 'new.js')), 'repo-write', 'a new file inside');
    assert.equal(deny(join(root, '.git', 'config')), 'repo-write');
    assert.equal(deny(root), 'repo-write');
    assert.equal(deny(join(dir, 'link', 'x.js')), 'repo-write', 'through a symlink');
    assert.equal(deny(join(root.toUpperCase(), 'src', 'x.js')), 'repo-write', 'in another case (APFS)');
    assert.equal(deny('src/x.js', root), 'repo-write', 'relative to the session cwd');
    assert.equal(deny(join(dir, 'outside', 'report.md')), null);
    assert.equal(deny(`${root}-sibling/x`), null, 'a sibling whose name starts the same');
});

function hook(t, payload, args, env = {}) {
    return spawnSync(process.execPath, [HOOK, ...args], {
        input: JSON.stringify(payload), encoding: 'utf-8', timeout: 15000,
        env: { PATH: process.env.PATH, ...env },
    });
}

test('the hook refuses with exit 2, tells the model to stop and report, and logs one events line (c)', (t) => {
    const { dir, root } = repo(t);
    const state = join(dir, 'state');
    const env = { MY_TEAM_STATE_ROOT: state, MY_TEAM_WORKER: 'tt/rv' };
    const args = ['--deny', 'push,repo-write', '--repo', root];

    const r = hook(t, { tool_name: 'Bash', tool_input: { command: 'git push origin main' }, cwd: root }, args, env);
    assert.equal(r.status, 2, r.stderr);
    assert.match(r.stderr, /push/);
    assert.match(r.stderr, /멈추고 pm/);
    const w = hook(t, { tool_name: 'Write', tool_input: { file_path: join(root, 'a.txt'), content: 'x' }, cwd: root }, args, env);
    assert.equal(w.status, 2, w.stderr);
    const n = hook(t, { tool_name: 'NotebookEdit', tool_input: { notebook_path: join(root, 'n.ipynb') }, cwd: root }, args, env);
    assert.equal(n.status, 2, n.stderr);

    for (const ok of [
        { tool_name: 'Bash', tool_input: { command: 'git status' }, cwd: root },
        { tool_name: 'Write', tool_input: { file_path: join(dir, 'outside', 'r.md'), content: 'x' }, cwd: root },
        { tool_name: 'Read', tool_input: { file_path: join(root, 'a.txt') }, cwd: root },
    ]) assert.equal(hook(t, ok, args, env).status, 0, JSON.stringify(ok));

    const events = readFileSync(join(state, 'events.jsonl'), 'utf-8').trim().split('\n').map((l) => JSON.parse(l));
    assert.equal(events.length, 3);
    assert.deepEqual({ ...events[0], ts: undefined }, {
        ts: undefined, type: 'tool-denied', team: 'tt', worker: 'rv', tool: 'Bash', rule: 'push', target: 'git push origin main',
    });
    assert.deepEqual([events[1].rule, events[1].target], ['repo-write', join(root, 'a.txt')]);
});

test('input the hook cannot read is refused, never let through', (t) => {
    const r = spawnSync('sh', ['-c', hookCommand(['push'], null)], { input: 'not json', encoding: 'utf-8', timeout: 15000 });
    assert.equal(r.status, 2, r.stderr);
    const crash = spawnSync('sh', ['-c', `${process.execPath} -e "process.exit(1)" || exit 2`], { encoding: 'utf-8' });
    assert.equal(crash.status, 2, 'the installed command turns any other failure into a refusal');
    assert.match(hookCommand(['push'], null), /\|\| exit 2$/);
});

test('a worker without deny launches as before; with deny a claude worker gets --settings, codex a warning (d, e, f)', (t) => {
    const { dir, root } = repo(t);
    const workerDir = join(dir, 'workers', 'rv');
    mkdirSync(workerDir, { recursive: true });

    assert.deepEqual(guardLaunch({ agentType: 'claude', deny: [], cwd: root, workerDir }), { args: [], warning: null });
    assert.equal(existsSync(join(workerDir, 'guard-settings.json')), false);

    const claude = guardLaunch({ agentType: 'claude', deny: ['push', 'repo-write'], cwd: join(root, 'src'), workerDir });
    assert.deepEqual(claude.args, ['--settings', join(workerDir, 'guard-settings.json')]);
    assert.equal(claude.warning, null);
    const settings = JSON.parse(readFileSync(claude.args[1], 'utf-8'));
    const pre = settings.hooks.PreToolUse;
    assert.equal(pre.length, 1);
    assert.match(pre[0].matcher, /Bash/);
    assert.match(pre[0].hooks[0].command, /--deny 'push,repo-write' --repo '/);
    assert.ok(pre[0].hooks[0].command.includes(root), 'the repository of the worker cwd, found from a subfolder');

    const codex = guardLaunch({ agentType: 'codex', deny: ['push'], cwd: root, workerDir: join(dir, 'workers', 'cx') });
    assert.deepEqual(codex.args, []);
    assert.match(codex.warning, /codex.*deny.*not applied/i);
});

test('config: deny is an optional list of push and repo-write', () => {
    const cwd = mkdtempSync(join(tmpdir(), 'mt-guard-cfg-'));
    try {
        const one = (deny) => validateConfig({ team_name: 'gg', workers: [{ name: 'a', agent_type: 'claude', cwd, ...(deny === undefined ? {} : { deny }) }] }).workers[0].deny;
        assert.deepEqual(one(undefined), []);
        assert.deepEqual(one(['push']), ['push']);
        assert.deepEqual(one(['repo-write', 'push']), ['push', 'repo-write']);
        assert.throws(() => one(['force-push']), /deny/);
        assert.throws(() => one('push'), /deny/);
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
});
