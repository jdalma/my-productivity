/**
 * The board's read side (T63d, rfc/board-design.md §6.1): the review queue (R64 §1 rows), a worker's inbox
 * and the whole board's status, on every store. Boards are filled through the write service.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { createBoard } from '../../src/board/core/service.js';
import { inbox, reviewQueue, status } from '../../src/board/core/queries.js';
import { createMemoryStore } from '../../src/board/store/memory/index.js';
import { createSqliteStore } from '../../src/board/store/sqlite/index.js';
import { SCHEMA_VERSION } from '../../src/board/core/contract.js';

const hasSqlite = await import('node:sqlite').then(() => true, () => false);
const ROSTER = [
    { name: 'pm', role: 'orchestrator' }, { name: 'core', role: 'worker' },
    { name: 'app', role: 'worker' }, { name: 'rv', role: 'worker' },
];
const H = (c) => c.repeat(40);
const BASE = H('0');

async function makeStore(kind, t) {
    if (kind === 'memory') return createMemoryStore();
    const dir = mkdtempSync(join(tmpdir(), 'mt-board-q-'));
    const store = createSqliteStore(join(dir, 'board.db'));
    await store.open();
    t.after(async () => { await store.close(); rmSync(dir, { recursive: true, force: true }); });
    return store;
}

function both(name, fn) {
    for (const kind of ['memory', 'sqlite']) {
        const skip = kind === 'sqlite' && !hasSqlite ? 'node:sqlite needs Node >= 22.13' : false;
        test(`[${kind}] ${name}`, { skip }, async (t) => {
            const store = await makeStore(kind, t);
            let tick = 0;
            const now = () => new Date(Date.UTC(2026, 10, 11, 0, 0, tick++)).toISOString();
            const git = { range: async (repo, base, commit) => ({ ancestor: true, commits: [commit] }) };
            const as = (actor) => createBoard({ store, roster: () => ROSTER, actor, now, git });
            await fn({ store, as });
        });
    }
}

const land = (id, commit, extra = {}) => ({
    id, repo: '/repo', commit, check: { cmd: 'npm test', result: '1/1' }, focus: ['one'], closes: [],
    report: '/r/c.md', review_report: '/r/R.md', ...extra,
});
const judge = (landing, commit, verdict, extra = {}) => ({
    landing, verdict, verified_commit: commit, report: '/r/R.md', rerun: { cmd: 'npm test', result: '1/1' }, findings: [], ...extra,
});
const full = { ticket: '/t/T.md', constraints: 'tmux -L only', base: BASE };

both('review queue: one row per open review request of the reviewer, with what R64 asks for', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'root', assignee: 'core', reviewer: 'rv', ...full });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    await as('rv').verdict(judge('T1#1', H('1'), 'changes', { findings: [{ code: 'M1', severity: 'must', summary: 's', repro: 'r' }, { code: 'L1', severity: 'low', summary: 'l', repro: 'r' }] }));
    await as('pm').finding({ id: 'R1 L1', state: 'backlog' });
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'fix', assignee: 'app', reviewer: 'rv', priority: 10, ...full });
    await as('app').take({ id: 'T1a' });
    await as('app').land(land('T1a', H('2'), { closes: ['R1 M1'] }));
    await as('app').land(land('T1a', H('3')));
    await as('pm').add({ id: 'T2', title: 'other', assignee: 'core', reviewer: 'app', ...full });
    await as('core').take({ id: 'T2' });
    await as('core').land(land('T2', H('4')));

    const q = await reviewQueue(store, ROSTER, 'rv');
    assert.deepEqual(q.queue.map((r) => r.landing.id), ['T1a#2'], 'the superseded T1a#1, T1 (changes) and T2 (app reviews) are not rv\'s');
    const row = q.queue[0];
    assert.deepEqual([row.task.id, row.task.ticket_path, row.task.constraints, row.parent.id], ['T1a', '/t/T.md', 'tmux -L only', 'T1']);
    assert.deepEqual([row.landing.commit, row.landing.base_commit, row.landing.commits, row.landing.focus, row.landing.review_report_path],
        [H('3'), BASE, [H('3')], ['one'], '/r/R.md']);
    assert.deepEqual(row.open_findings.map((f) => [f.id, f.state, f.fixed_in]), [['R1 M1', 'fixed', 'T1a#2']]);
    assert.deepEqual(row.settled_findings.map((f) => [f.id, f.state]), [['R1 L1', 'backlog']]);
    assert.deepEqual(q.incomplete, []);
    assert.deepEqual([row.next_verdict, row.verdicts.map((v) => [v.id, v.verdict])], ['R1a', [['R1', 'changes']]], 'R69 L4');
    assert.equal(row.previous_commit, H('2'), 'R70 R2: the commit of the landing this one supersedes');
    assert.equal((await reviewQueue(store, ROSTER, 'app')).queue[0].previous_commit, null);
    assert.deepEqual((await reviewQueue(store, ROSTER, 'app')).queue.map((r) => [r.landing.id, r.next_verdict]), [['T2#1', 'R2']]);
    await as('app').note({ id: 'T1a', body: 'context for the reviewer' });
    assert.deepEqual((await reviewQueue(store, ROSTER, 'rv')).queue[0].notes.map((n) => n.body), ['context for the reviewer'], 'R69 R1: a note with no "to" shows on the row');
});

both('review queue: a task without a ticket or constraints is listed as incomplete; pm judges tasks with no reviewer; priority orders', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'bare', assignee: 'core', base: BASE });
    await as('pm').assign({ id: 'T1', reviewer: 'rv' });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    const q = await reviewQueue(store, ROSTER, 'rv');
    assert.deepEqual(q.queue, []);
    assert.deepEqual(q.incomplete, [{ landing: 'T1#1', task: 'T1', missing: ['ticket_path', 'constraints'] }]);
    await as('pm').add({ id: 'T9', title: 'blank', assignee: 'app', reviewer: 'rv', ticket: '/t.md', constraints: '  ', base: BASE });
    await as('app').take({ id: 'T9' });
    const { review_report, ...noSuggestion } = land('T9', H('9'));
    await as('app').land(noSuggestion);
    assert.deepEqual((await reviewQueue(store, ROSTER, 'rv')).incomplete.map((r) => [r.task, r.missing]), [['T1', ['ticket_path', 'constraints']], ['T9', ['constraints']]],
        'R71 R2: a blank constraint is as incomplete as none; a missing review report path is not');

    await as('pm').add({ id: 'T2', title: 'low', assignee: 'core', priority: 50, ...full });
    await as('pm').add({ id: 'T3', title: 'high', assignee: 'app', priority: 5, ...full });
    for (const [who, id, c] of [['core', 'T2', '2'], ['app', 'T3', '3']]) { await as(who).take({ id }); await as(who).land(land(id, H(c))); }
    assert.deepEqual((await reviewQueue(store, ROSTER, 'pm')).queue.map((r) => r.task.id), ['T3', 'T2']);
    await as('pm').cancel({ id: 'T3' });
    assert.deepEqual((await reviewQueue(store, ROSTER, 'pm')).queue.map((r) => r.task.id), ['T2'], 'a cancelled task leaves the queue');
});

both('inbox: my unfinished work, my reviews, notes to me and announcements after my cursor', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'a', assignee: 'core', reviewer: 'rv', priority: 20, ...full });
    await as('pm').add({ id: 'T2', title: 'b', assignee: 'core', reviewer: 'rv', priority: 10, ...full });
    await as('pm').add({ id: 'T3', title: 'c', assignee: 'core', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T4', title: 'd', assignee: 'app', reviewer: 'core', ...full });
    await as('core').take({ id: 'T3' });
    await as('core').land(land('T3', H('3')));
    await as('app').take({ id: 'T4' });
    await as('app').land(land('T4', H('4')));
    await as('pm').note({ id: 'T1', body: 'look at x', to: ['core'] });
    await as('pm').note({ body: 'for app', to: ['app'] });
    await as('pm').announce({ body: 'rule one' });

    const first = await inbox(store, ROSTER, 'core');
    assert.deepEqual(first.tasks.map((t) => [t.id, t.state]), [['T2', 'ready'], ['T1', 'ready']], 'T3 waits on its reviewer');
    assert.deepEqual(first.review_queue.map((r) => r.landing.id), ['T4#1']);
    assert.deepEqual(first.notes.map((n) => n.body), ['look at x']);
    assert.deepEqual(first.announcements.map((a) => a.body), ['rule one']);

    await as('pm').announce({ body: 'rule two' });
    const next = await inbox(store, ROSTER, 'core', first.cursor);
    assert.deepEqual([next.notes, next.announcements.map((a) => a.body)], [[], ['rule two']]);
    assert.ok(next.cursor.announcement > first.cursor.announcement);
    assert.equal(next.cursor.board, (await store.describe()).board_id);
    const elsewhere = await inbox(store, ROSTER, 'core', { ...next.cursor, board: 'f'.repeat(32) });
    assert.deepEqual(elsewhere.announcements.map((a) => a.body), ['rule one', 'rule two'], 'R69 R2: a cursor of another board starts from the beginning');
});

both('status: every task, each worker\'s load, open findings, recent changes; or one family in full', async ({ store, as }) => {
    await as('pm').add({ id: 'T1', title: 'root', assignee: 'core', reviewer: 'rv', ...full });
    await as('core').take({ id: 'T1' });
    await as('core').land(land('T1', H('1')));
    await as('rv').verdict(judge('T1#1', H('1'), 'changes', { findings: [{ code: 'M1', severity: 'must', summary: 's', repro: 'r' }] }));
    await as('pm').add({ id: 'T1a', parent: 'T1', title: 'fix', assignee: 'app', reviewer: 'rv', ...full });
    await as('pm').add({ id: 'T2', title: 'other' });

    const all = await status(store, ROSTER);
    assert.equal(all.store.schema_version, SCHEMA_VERSION);
    assert.deepEqual(all.tasks.map((t) => [t.id, t.state]), [['T1', 'changes'], ['T1a', 'ready'], ['T2', 'new']]);
    assert.deepEqual(all.workers.find((w) => w.name === 'core'), { name: 'core', role: 'worker', assigned: 1, reviewing: 0 });
    assert.deepEqual(all.workers.find((w) => w.name === 'rv'), { name: 'rv', role: 'worker', assigned: 0, reviewing: 2 });
    assert.deepEqual(all.workers.find((w) => w.name === 'pm'), { name: 'pm', role: 'orchestrator', assigned: 0, reviewing: 1 }, 'pm judges T2, which has no reviewer');
    assert.deepEqual(all.open_findings.map((f) => f.id), ['R1 M1']);
    assert.deepEqual(all.recent.at(-1).action, 'add');
    assert.ok(all.recent.length <= 20);

    await as('pm').announce({ body: 'user decided: sqlite' });
    await as('core').note({ id: 'T1', body: 'why this way' });
    const later = await status(store, ROSTER);
    assert.deepEqual(later.announcements.map((a) => a.body), ['user decided: sqlite'], 'R69 R4');
    const fam = await status(store, ROSTER, { task: 'T1a' });
    assert.deepEqual(fam.notes.map((n) => n.body), ['why this way'], 'R69 R1');
    assert.deepEqual([fam.root.id, fam.tasks.map((t) => t.id)], ['T1', ['T1', 'T1a']]);
    assert.deepEqual(fam.landings.map((l) => l.id), ['T1#1']);
    assert.deepEqual(fam.verdicts.map((v) => [v.id, v.verdict]), [['R1', 'changes']]);
    assert.deepEqual(fam.findings.map((f) => f.id), ['R1 M1']);
    await assert.rejects(status(store, ROSTER, { task: 'T9' }), (err) => err.code === 'not-found');
});
