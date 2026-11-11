/**
 * A notice types into a pane only while that pane is still the recipient's (T63e1, R70 R1). A manifest goes
 * stale: after a team stops or tmux restarts, its pane ids can belong to another team's panes. Before the
 * trigger, the pane's session and @worker_name must match the manifest's session and the recipient; when
 * they do not, or tmux cannot say, nothing is typed and the message waits in the mailbox, with a warning.
 * send-message and the board's notices go through the same check.
 *
 * On a tmux server of this file's own (under the run's -L server): panes record what is typed into them.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiSendMessage } from '../../src/commands/api/send-message.js';
import { boardFor } from '../../src/board/compose.js';
import { createMemoryStore } from '../../src/board/store/memory/index.js';
import { tmuxExec } from '../../src/lib/tmux-utils.js';

if (process.env.MY_TEAM_TEST_TMUX) {
    const own = `${process.env.MY_TEAM_TEST_TMUX}-owner`;
    process.env.MY_TEAM_TEST_TMUX = own;
    test.after(() => {
        try { tmuxExec(['kill-server'], { stdio: 'pipe' }); } catch { /* none */ }
        rmSync(`/tmp/tmux-${process.getuid()}/${own}`, { force: true });
    });
}

const sink = (log) => `while IFS= read -r l; do printf '%s\\n' "$l" >> '${log}'; printf '\\033[1A\\033[2K'; done`;

/** A session with one pane tagged as `worker`; returns its pane id and what has been typed into it. */
function pane(t, base, session, worker) {
    const log = join(base, `${session}.typed`);
    tmuxExec(['new-session', '-d', '-s', session, sink(log)], { stdio: 'pipe' });
    t.after(() => { try { tmuxExec(['kill-session', '-t', session], { stdio: 'pipe' }); } catch { /* gone */ } });
    const id = tmuxExec(['display-message', '-p', '-t', session, '#{pane_id}'], { stdio: 'pipe' }).trim();
    tmuxExec(['set-option', '-p', '-t', id, '@worker_name', worker], { stdio: 'pipe' });
    return { id, typed: () => (existsSync(log) ? readFileSync(log, 'utf-8').split('\n').filter(Boolean) : []) };
}

function team(t, { session, workers }) {
    const base = realpathSync(mkdtempSync(join(tmpdir(), 'mt-owner-')));
    t.after(() => rmSync(base, { recursive: true, force: true }));
    const root = join(base, 'own-team');
    mkdirSync(join(root, 'mailbox'), { recursive: true });
    const manifest = { team_name: 'own-team', state_root: root, session_name: `${session}:0`, board: { store: 'memory' }, workers };
    writeFileSync(join(root, 'manifest.json'), JSON.stringify(manifest));
    const savedBase = process.env.MY_TEAM_STATE_ROOT_BASE;
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    t.after(() => {
        if (savedBase === undefined) delete process.env.MY_TEAM_STATE_ROOT_BASE; else process.env.MY_TEAM_STATE_ROOT_BASE = savedBase;
        delete process.env.MY_TEAM_STATE_ROOT;
    });
    const spool = (w) => (existsSync(join(root, 'incoming-spool', w)) ? readdirSync(join(root, 'incoming-spool', w)).length : 0);
    return { base, root, manifest, spool };
}

const env = {};

test('a manifest pane id that now belongs to another team\'s pane: nothing typed there, the message in the mailbox, a warning', async (t) => {
    const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'mt-owner-panes-')));
    t.after(() => rmSync(scratch, { recursive: true, force: true }));
    const mine = pane(t, scratch, 'own-session', 'alice');
    const theirs = pane(t, scratch, 'other-team-session', 'bob');
    const { spool } = team(t, { session: 'own-session', workers: [{ name: 'alice', pane_id: mine.id }, { name: 'bob', pane_id: theirs.id }] });

    const r = await runApiSendMessage({ team_name: 'own-team', from_worker: 'alice', to_worker: 'bob', body: 'hello' }, { env });
    assert.equal(r.ok, true);
    assert.deepEqual(theirs.typed(), [], 'the other team\'s pane got nothing');
    assert.equal(spool('bob'), 1, 'the message waits in bob\'s mailbox');
    assert.match(r.warning ?? '', /not typed/);
});

test('a pane in the team\'s own session that now carries another worker\'s name: nothing typed (a split-pane team\'s case)', async (t) => {
    const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'mt-owner-panes-')));
    t.after(() => rmSync(scratch, { recursive: true, force: true }));
    const mine = pane(t, scratch, 'own-session5', 'alice');
    const otherPane = tmuxExec(['split-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'own-session5', sink(join(scratch, 'carol5.typed'))], { stdio: 'pipe' }).trim();
    tmuxExec(['set-option', '-p', '-t', otherPane, '@worker_name', 'carol'], { stdio: 'pipe' });
    const { spool } = team(t, { session: 'own-session5', workers: [{ name: 'alice', pane_id: mine.id }, { name: 'bob', pane_id: otherPane }] });
    const r = await runApiSendMessage({ team_name: 'own-team', from_worker: 'alice', to_worker: 'bob', body: 'x' }, { env });
    assert.equal(existsSync(join(scratch, 'carol5.typed')), false, 'carol\'s pane got nothing');
    assert.equal(spool('bob'), 1);
    assert.match(r.warning ?? '', /not typed/);
});

test('a pane that is gone, or a manifest without a session: nothing typed, the message kept, a warning', async (t) => {
    const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'mt-owner-panes-')));
    t.after(() => rmSync(scratch, { recursive: true, force: true }));
    const mine = pane(t, scratch, 'own-session2', 'alice');
    const { spool, root, manifest } = team(t, { session: 'own-session2', workers: [{ name: 'alice', pane_id: mine.id }, { name: 'bob', pane_id: '%9999' }] });
    const gone = await runApiSendMessage({ team_name: 'own-team', from_worker: 'alice', to_worker: 'bob', body: 'x' }, { env });
    assert.equal(spool('bob'), 1);
    assert.match(gone.warning ?? '', /not typed/);

    delete manifest.session_name;
    manifest.workers[1].pane_id = mine.id;
    writeFileSync(join(root, 'manifest.json'), JSON.stringify(manifest));
    const r = await runApiSendMessage({ team_name: 'own-team', from_worker: 'bob', to_worker: 'alice', body: 'y' }, { env });
    assert.deepEqual(mine.typed(), [], 'no session to check against: no trigger');
    assert.equal(spool('alice'), 1);
    assert.match(r.warning ?? '', /not typed/);
});

test('the team\'s own pane still gets the trigger, with no warning', async (t) => {
    const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'mt-owner-panes-')));
    t.after(() => rmSync(scratch, { recursive: true, force: true }));
    const alice = pane(t, scratch, 'own-session3', 'alice');
    const bobPane = tmuxExec(['split-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'own-session3', sink(join(scratch, 'bob3.typed'))], { stdio: 'pipe' }).trim();
    tmuxExec(['set-option', '-p', '-t', bobPane, '@worker_name', 'bob'], { stdio: 'pipe' });
    const { spool } = team(t, { session: 'own-session3', workers: [{ name: 'alice', pane_id: alice.id }, { name: 'bob', pane_id: bobPane }] });
    const r = await runApiSendMessage({ team_name: 'own-team', from_worker: 'alice', to_worker: 'bob', body: 'hi' }, { env });
    assert.equal(r.warning, undefined, r.warning);
    assert.equal(spool('bob'), 1);
    const typed = readFileSync(join(scratch, 'bob3.typed'), 'utf-8').split('\n').filter(Boolean);
    assert.deepEqual(typed, ['new-message:alice']);
});

test('board notices take the same check, and leave process.env as it was (R70 L3)', async (t) => {
    const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'mt-owner-panes-')));
    t.after(() => rmSync(scratch, { recursive: true, force: true }));
    const mine = pane(t, scratch, 'own-session4', 'pm');
    const theirs = pane(t, scratch, 'other-team-session4', 'core');
    const { manifest, spool } = team(t, { session: 'own-session4', workers: [{ name: 'pm', role: 'orchestrator', pane_id: mine.id }, { name: 'core', role: 'worker', pane_id: theirs.id }] });
    const before = process.env.MY_TEAM_STATE_ROOT;
    const roster = manifest.workers.map((w) => ({ name: w.name, role: w.role }));
    const r = await boardFor({ store: createMemoryStore(), roster, manifest, actor: 'pm' }).add({ id: 'T1', title: 't', assignee: 'core' });
    assert.equal(r.ok, true);
    assert.deepEqual(theirs.typed(), []);
    assert.equal(spool('core'), 1);
    assert.match(r.warning ?? '', /not typed/);
    assert.equal(process.env.MY_TEAM_STATE_ROOT, before);
});
