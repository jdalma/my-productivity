/**
 * The tmux shim on a worker's PATH (T56): without -L or -S a tmux call reaches the user's server, so only
 * reading commands pass; the rest are refused before tmux runs, and each refusal lands in events.jsonl.
 *
 * Every tmux here is a server of the test's own. The shim finds "the real tmux" on PATH, and the only one
 * on that PATH is a wrapper that sends a call without -L/-S to a control server (-S <tmp socket>), standing
 * in for the user's default server: a call the shim wrongly lets through hits the control server, never the
 * user's.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

import { findRealTmux, tmuxShimVerdict } from '../../src/lib/tmux-guard.js';
import { buildWorkerStartCommand } from '../../src/lib/tmux-session.js';

const SHIM_DIR = fileURLToPath(new URL('../../shim', import.meta.url));
const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));

test('without -L or -S only reading commands pass; anything not known to read is refused', () => {
    const env = { TMUX_TMPDIR: '/nonexistent' };
    const allow = (args) => tmuxShimVerdict(args, env, 501).allow;
    for (const args of [
        ['ls'], ['list-sessions', '-F', '#{session_name}'], ['lsp', '-a'], ['list-clients'], ['list-windows', '-a'],
        ['display-message', '-p', '#S'], ['display', '-t', '%1', '-p', '#{pane_id}'], ['display-message', '-pt', '%1', '#S'],
        ['capture-pane', '-p', '-t', '%1'], ['capture-pane', '-ep', '-S', '-20', '-t', '%1'],
        ['show-options', '-g', 'extended-keys'], ['show', '-gv', 'status'], ['has-session', '-t', 'x'], ['-V'],
        ['-u', 'ls'], ['-f', '/dev/null', 'ls'],
    ]) assert.equal(allow(args), true, args.join(' '));
    for (const args of [
        [], ['kill-server'], ['kill-session', '-t', 'x'], ['send-keys', '-t', '%1', 'x'], ['rename-window', 'x'],
        ['new-session', '-d'], ['attach'], ['set-option', '-g', 'status', 'off'], ['kill-ser'],
        ['display-message', 'hi'], ['display-message', '-I', '-p', '-t', '%1'], ['capture-pane', '-t', '%1'],
        ['ls', ';', 'kill-server'], ['ls;', 'kill-server'], ['ls', '\\;', 'kill-server'],
        ['-C', 'attach'], ['-c', 'tmux kill-server'], ['-x', 'ls'], ['display-message', '-z', '-p'],
    ]) assert.equal(allow(args), false, args.join(' '));
});

test('-L or -S passes anything, unless it names the default server', () => {
    const v = (args, env = {}) => tmuxShimVerdict(args, env, 501).allow;
    assert.equal(v(['-L', 'scratch', 'kill-server']), true);
    assert.equal(v(['-Lscratch', 'send-keys', '-t', '%1', 'x']), true);
    assert.equal(v(['-S', '/tmp/my-socket', 'kill-server']), true);
    assert.equal(v(['-L', 'default', 'kill-server']), false);
    assert.equal(v(['-S', '/tmp/tmux-501/default', 'kill-server']), false);
    assert.equal(v(['-S', '/private/tmp/tmux-501/default', 'kill-server']), false);
    assert.equal(v(['-S', '/tmp/tmux-501//default', 'kill-server']), false);
    assert.equal(v(['-S', '/tmp/x/tmux-501/default', 'kill-server'], { TMUX_TMPDIR: '/tmp/x' }), false);
    assert.equal(v(['-S', '/tmp/tmux-501/default', 'kill-server'], { TMUX_TMPDIR: '/tmp/x' }), false, 'a missing TMUX_TMPDIR falls back');
    assert.equal(v(['-S', '/tmp/s/team', 'kill-server'], { TMUX: '/tmp/s/team,123,0' }), false, 'the server the worker is in');
    assert.equal(v(['-S', '/tmp/tmux-501/default', 'ls']), true, 'reading the default server stays allowed');
    // no socket yet, so realpath cannot say: a name that differs only in case is still taken for the default
    const gone = { TMUX_TMPDIR: '/nonexistent-t56a' };
    assert.equal(v(['-S', '/nonexistent-t56a/TMUX-501/DEFAULT', 'kill-server'], gone), false);
    assert.equal(v(['-L', 'Default', 'kill-server'], gone), false);
});

test('a worker launches with the shim first on PATH, after its rc file has run', () => {
    const cmd = buildWorkerStartCommand({ launchBinary: 'claude', envVars: {} });
    const script = cmd.match(/'-l?c' '(.*?)' '--'/)?.[1] ?? cmd;
    const rc = script.indexOf('. '), path = script.indexOf(SHIM_DIR);
    assert.ok(path > rc, cmd);
    assert.ok(path < script.indexOf('exec'), cmd);
});

/** Not `command -v tmux`: in a worker started since T56 that is the shim, and the wrapper below would call itself (R57 M2). */
function realTmux(path = process.env.PATH) {
    const real = findRealTmux(path);
    assert.ok(real, 'no tmux on PATH');
    return real;
}

const LIMIT = { timeout: 15000 };

test('with the shim first on PATH, the tests still find the real tmux, so the wrapper never calls the shim (R57 M2)', () => {
    const real = realTmux(`${SHIM_DIR}:${process.env.PATH}`);
    assert.notEqual(real, join(SHIM_DIR, 'tmux'));
    assert.match(execFileSync(real, ['-V'], { encoding: 'utf-8', ...LIMIT }), /^tmux /);
});

/** A control server on a socket of the test's own, and a PATH whose only tmux is the shim, then a wrapper to it. */
function setup(t) {
    const dir = mkdtempSync('/tmp/mt-shim-');
    const ctl = join(dir, 'ctl');
    const real = realTmux();
    const bin = join(dir, 'bin');
    mkdirSync(bin);
    writeFileSync(join(bin, 'tmux'),
        `#!/bin/sh\ncase "$1" in -L|-S) exec '${real}' "$@";; esac\nexec '${real}' -S '${ctl}' "$@"\n`);
    chmodSync(join(bin, 'tmux'), 0o755);
    symlinkSync(process.execPath, join(bin, 'node'));
    const ctlTmux = (...args) => execFileSync(real, ['-S', ctl, ...args], { encoding: 'utf-8', ...LIMIT });
    ctlTmux('-f', '/dev/null', 'new-session', '-d', '-s', 'ctl', '-n', 'keep',
        'sh -c \'while IFS= read -r l; do echo "GOT:$l"; done\'');
    const state = join(dir, 'state');
    mkdirSync(state);
    t.after(() => {
        spawnSync(real, ['-S', ctl, 'kill-server']);
        rmSync(dir, { recursive: true, force: true });
    });
    const env = {
        HOME: process.env.HOME, PATH: `${SHIM_DIR}:${bin}:/usr/bin:/bin`, TMUX_TMPDIR: join(dir, 'gone'),
        MY_TEAM_STATE_ROOT: state, OMC_TEAM_WORKER: 't56/core', MY_TEAM_WORKER: 't56/core',
    };
    const sh = (script) => spawnSync('/bin/sh', ['-c', script], { env, encoding: 'utf-8', ...LIMIT });
    const ctlAlive = () => spawnSync(real, ['-S', ctl, 'has-session', '-t', 'ctl'], LIMIT).status === 0;
    return { dir, ctl, real, bin, env, sh, ctlTmux, ctlAlive, state };
}

test('a worker resolves tmux to the shim', (t) => {
    const s = setup(t);
    assert.equal(s.sh('command -v tmux').stdout.trim(), join(SHIM_DIR, 'tmux'));
});

test('12:51 again: kill-server without -L from inside a script, TMUX_TMPDIR missing, is refused (a)', (t) => {
    const s = setup(t);
    writeFileSync(join(s.dir, 'trap.sh'), 'TMUX_TMPDIR=/nonexistent-t56 tmux kill-server\n');
    const r = s.sh(`sh ${join(s.dir, 'trap.sh')}`);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /사용자 tmux 서버에 대한 쓰기 명령은 거부됨\. -L 또는 -S로 격리 서버를 지정/);
    assert.equal(s.ctlAlive(), true);
});

test('-L <scratch> kill-server passes and ends only that server (b)', (t) => {
    const s = setup(t);
    const name = `mt-shim-b-${process.pid}`;
    execFileSync(s.real, ['-L', name, '-f', '/dev/null', 'new-session', '-d', 'sleep 60']);
    t.after(() => {
        spawnSync(s.real, ['-L', name, 'kill-server'], LIMIT);
        rmSync(join('/tmp', `tmux-${process.getuid()}`, name), { force: true });  // kill-server leaves the socket file
    });
    const r = s.sh(`tmux -L ${name} kill-server`);
    assert.equal(r.status, 0, r.stderr);
    assert.notEqual(spawnSync(s.real, ['-L', name, 'has-session']).status, 0);
    assert.equal(s.ctlAlive(), true);
});

test('send-keys, kill-session and rename-window without -L are refused and change nothing (c)', (t) => {
    const s = setup(t);
    for (const cmd of ['send-keys -t ctl:keep TYPED Enter', 'kill-session -t ctl', 'rename-window -t ctl:keep renamed']) {
        const r = s.sh(`tmux ${cmd}`);
        assert.notEqual(r.status, 0, cmd);
        assert.match(r.stderr, /거부됨/, cmd);
    }
    assert.equal(s.ctlAlive(), true);
    assert.equal(s.ctlTmux('display-message', '-p', '-t', 'ctl', '#W').trim(), 'keep');
    assert.doesNotMatch(s.ctlTmux('capture-pane', '-p', '-t', 'ctl'), /TYPED/);
});

test('ls and display-message -p without -L pass (d)', (t) => {
    const s = setup(t);
    const ls = s.sh('tmux ls');
    assert.equal(ls.status, 0, ls.stderr);
    assert.match(ls.stdout, /^ctl: /m);
    const d = s.sh(`tmux display-message -p -t ctl '#S:#W'`);
    assert.equal(d.status, 0, d.stderr);
    assert.equal(d.stdout.trim(), 'ctl:keep');
});

test('a refusal is one events.jsonl line with the team, the worker and the arguments (e)', (t) => {
    const s = setup(t);
    s.sh('tmux kill-session -t ctl');
    const lines = readFileSync(join(s.state, 'events.jsonl'), 'utf-8').trim().split('\n').map((l) => JSON.parse(l));
    assert.equal(lines.length, 1);
    const [e] = lines;
    assert.equal(e.type, 'tmux-denied');
    assert.equal(e.team, 't56');
    assert.equal(e.worker, 'core');
    assert.deepEqual(e.args, ['kill-session', '-t', 'ctl']);
    assert.ok(!Number.isNaN(Date.parse(e.ts)));
});

test('my-team itself skips the shim: send-message from a worker with the shim on PATH still notifies (f)', async (t) => {
    const s = setup(t);
    const base = join(s.dir, 'teams');
    const stateRoot = join(base, 't56');
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
    const pane = s.ctlTmux('display-message', '-p', '-t', 'ctl', '#{pane_id}').trim();
    writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify({
        team_name: 't56', state_root: stateRoot, session_name: 'ctl',
        workers: [{ name: 'alice', pane_id: '%999' }, { name: 'bob', pane_id: pane }],
    }));
    const input = JSON.stringify({ team_name: 't56', from_worker: 'alice', to_worker: 'bob', body: 'hi' });
    const r = spawnSync(process.execPath, [MY_TEAM, 'api', 'send-message', '--input', input], {
        env: { ...s.env, MY_TEAM_STATE_ROOT_BASE: base, MY_TEAM_STATE_ROOT: stateRoot, OMC_TEAM_WORKER: 't56/alice' },
        encoding: 'utf-8', timeout: 20000,
    });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(s.ctlTmux('capture-pane', '-p', '-S', '-', '-t', pane), /GOT:new-message:alice/);
    assert.equal(existsSync(join(s.state, 'events.jsonl')), false, 'the shim refused nothing');
    const events = readFileSync(join(stateRoot, 'events.jsonl'), 'utf-8');
    assert.doesNotMatch(events, /tmux-denied/);
});

test('the default server under another name is still the default server: symlink, case, -L paths, -L of $TMUX (R57 M1)', (t) => {
    const s = setup(t);
    const uid = process.getuid();
    // a fake default server in a TMUX_TMPDIR that exists, so no call can fall back to /tmp
    const tmpdir = join(s.dir, 'td');
    const sockets = join(tmpdir, `tmux-${uid}`);
    mkdirSync(sockets, { recursive: true, mode: 0o700 });
    mkdirSync(join(s.dir, 'l'));
    symlinkSync(join(sockets, 'default'), join(s.dir, 'l', 'sock'));
    const fake = { default: join(sockets, 'default'), work: join(sockets, 'work') };
    const up = (path) => {
        if (spawnSync(s.real, ['-S', path, 'has-session'], LIMIT).status !== 0) {
            execFileSync(s.real, ['-S', path, '-f', '/dev/null', 'new-session', '-d', 'sleep 600'], LIMIT);
        }
    };
    const alive = (path) => spawnSync(s.real, ['-S', path, 'has-session'], LIMIT).status === 0;
    t.after(() => { for (const p of Object.values(fake)) spawnSync(s.real, ['-S', p, 'kill-server'], LIMIT); });
    const env = { ...s.env, PATH: `${SHIM_DIR}:${dirname(s.real)}:/usr/bin:/bin`, TMUX_TMPDIR: tmpdir };
    for (const [args, server, extra] of [
        [['-S', join(s.dir, 'l', 'sock')], 'default'],
        [['-S', join(tmpdir, `TMUX-${uid}`, 'DEFAULT')], 'default'],
        [['-L', 'DEFAULT'], 'default'],
        [['-L', './default'], 'default'],
        [['-L', `../tmux-${uid}/default`], 'default'],
        [['-L', 'work'], 'work', { TMUX: `${fake.work},1,0` }],
    ]) {
        up(fake[server]);
        assert.ok(existsSync(sockets), 'the fake socket folder is there');
        const r = spawnSync('tmux', [...args, 'kill-server'], { env: { ...env, ...extra }, encoding: 'utf-8', ...LIMIT });
        assert.notEqual(r.status, 0, args.join(' '));
        assert.match(r.stderr, /거부됨/, args.join(' '));
        assert.equal(alive(fake[server]), true, args.join(' '));
    }
    // a name of its own still passes
    const r = spawnSync('tmux', ['-L', 'scratch-of-its-own', 'kill-server'], { env, encoding: 'utf-8', ...LIMIT });
    assert.doesNotMatch(r.stderr, /거부됨/);
});
