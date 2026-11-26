/**
 * T43 (D15): a worker process leaves team_name, and the worker it acts as, out of `my-team api` input:
 * MY_TEAM_WORKER (`<team>/<worker>`) fills them. A value that names another team or worker is refused as before;
 * without the variable (the user's shell) they stay required. Through the real CLI, under a temporary state base.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));
const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const needsSqlite = hasSqlite ? {} : { skip: 'node:sqlite needs Node >= 22.13' };

function team(t) {
    const base = mkdtempSync(join(tmpdir(), 'mt-pinned-'));
    t.after(() => rmSync(base, { recursive: true, force: true }));
    const root = join(base, 'bt');
    for (const d of ['mailbox', 'archive']) mkdirSync(join(root, d), { recursive: true });
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: 'bt', state_root: root, session_name: 'my-team-bt-x:0', board: { store: 'sqlite' },
        workers: [{ name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' }].map((w) => ({ ...w, agent_type: 'claude', pane_id: '%999' })),
    }));
    return base;
}

function cli(base, command, input, worker) {
    const env = { ...process.env, MY_TEAM_STATE_ROOT_BASE: base };
    for (const k of ['MY_TEAM_WORKER', 'OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT', 'TMUX', 'TMUX_PANE']) delete env[k];
    if (worker) env.MY_TEAM_WORKER = worker;
    const r = spawnSync(process.execPath, [MY_TEAM, 'api', command, '--input', JSON.stringify(input), '--json'], { env, encoding: 'utf-8' });
    let json = null;
    try { json = JSON.parse(r.stdout); } catch { /* not JSON */ }
    return { code: r.status, json, err: r.stderr };
}

test('T43: a worker leaves team_name and itself out; MY_TEAM_WORKER fills them', needsSqlite, (t) => {
    const base = team(t);
    const inbox = cli(base, 'board-inbox', {}, 'bt/core');
    assert.deepEqual([inbox.code, inbox.json?.worker], [0, 'core'], inbox.err);
    assert.equal(cli(base, 'board-status', {}, 'bt/core').code, 0);
    const mail = cli(base, 'mailbox-list', {}, 'bt/core');
    assert.deepEqual([mail.code, mail.json?.worker], [0, 'core'], mail.err);
    assert.equal(cli(base, 'roster', {}, 'bt/core').json?.team_name, 'bt');
    const take = cli(base, 'board-take', { id: 'T9' }, 'bt/core');
    assert.notEqual(take.json?.code, 'invalid', 'board writes get team_name too: it fails on the task, not on the input');
    assert.match(take.json?.message ?? '', /T9/);
});

test('T43: a team_name or worker other than MY_TEAM_WORKER\'s is refused as before', needsSqlite, (t) => {
    const base = team(t);
    assert.equal(cli(base, 'board-inbox', { team_name: 'bt' }, 'other/core').json?.code, 'forbidden', 'a worker of another team names this one');
    assert.equal(cli(base, 'board-inbox', { worker: 'pm' }, 'bt/core').json?.code, 'forbidden');
    const mail = cli(base, 'mailbox-list', { worker: 'pm' }, 'bt/core');
    assert.equal(mail.code, 1);
    assert.match(mail.err, /started as 'core'/);
    assert.equal(cli(base, 'board-inbox', { team_name: 'bt', worker: 'core' }, 'bt/core').code, 0, 'naming them as before still works');
});

test('T43: without MY_TEAM_WORKER (the user\'s shell) team_name and the worker stay required', needsSqlite, (t) => {
    const base = team(t);
    const status = cli(base, 'board-status', {});
    assert.deepEqual([status.code, status.json?.code], [1, 'invalid']);
    assert.match(status.json?.message ?? '', /team_name is required/);
    const mail = cli(base, 'mailbox-list', { team_name: 'bt' });
    assert.equal(mail.code, 1);
    assert.match(mail.err, /worker is required/);
});

test('T43: a board write from the user\'s shell names the field it reads, "by"', needsSqlite, (t) => {
    const base = team(t);
    const take = cli(base, 'board-take', { team_name: 'bt', id: 'T1' });
    assert.equal(take.json?.code, 'invalid');
    assert.match(take.json.message, /"by" in the input/);
    const inbox = cli(base, 'board-inbox', { team_name: 'bt' });
    assert.match(inbox.json?.message ?? '', /"worker" in the input/, 'the reads take "worker"');
});

test('T43: each api command\'s --help names its input fields, so AGENTS.md need not spell out the JSON', () => {
    const help = (...args) => spawnSync(process.execPath, [MY_TEAM, 'api', ...args, '--help'], { encoding: 'utf-8' }).stdout.replace(/\s+/g, ' ');
    assert.match(help(), /--help names its --input fields[^.]*\. In a worker process MY_TEAM_WORKER gives team_name/);
    const fields = {
        'send-message': /Input: to_worker, kind, body; reply_to, task, need, board_error, to_team/,
        'mailbox-list': /Optional input: unread_only/,
        'mailbox-mark-delivered': /Input: message_id/,
        'archive-lookup': /Input: message_id/,
        'board-status': /Optional input: task, open/,
        'board-inbox': /Optional input: since/,
        'board-take': /: id\b/,
        'board-land': /: id, commit, check \{cmd,result\}, focus, report; closes/,
        'board-wait': /: id, question, context, options \[\{label, detail, pros, cons\}/,
    };
    for (const [command, re] of Object.entries(fields)) assert.match(help(command), re, command);
});
