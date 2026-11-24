/**
 * mailbox-list, mailbox-mark-delivered and archive-lookup act as the worker the calling process was started as
 * (T7, T58's rule): with MY_TEAM_WORKER (`<team>/<worker>`) set, the input's team_name and worker must be that
 * team and worker, so a worker cannot absorb another worker's spool or mark its mail consumed. Without the
 * variable (the user's shell) the input stands. A guard against mistakes, not authentication.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiMailboxList } from '../../src/commands/api/mailbox-list.js';
import { runApiMailboxMarkDelivered } from '../../src/commands/api/mailbox-mark-delivered.js';
import { runApiArchiveLookup } from '../../src/commands/api/archive-lookup.js';
import { MAILBOX_SCHEMA_VERSION } from '../../src/lib/tmux-comm.js';

const MSG = { message_id: 'm-1', from_worker: 'alice', to_worker: 'bob', body: 'hi', reply_to: null, expects_reply: false, created_at: '2026-01-01T00:00:00Z' };

/** Team t1 of alice and bob. bob has m-1 unread in his mailbox, s-1 in his spool, m-1 in his archive. */
function setup(t) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-pin-'));
    const root = join(base, 't1');
    for (const d of ['mailbox', 'archive', join('incoming-spool', 'bob')]) mkdirSync(join(root, d), { recursive: true });
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({
        team_name: 't1', state_root: root, workers: [{ name: 'alice', pane_id: '%98' }, { name: 'bob', pane_id: '%99' }],
    }));
    writeFileSync(join(root, 'mailbox', 'bob.json'), JSON.stringify({
        schema_version: MAILBOX_SCHEMA_VERSION, worker: 'bob', inbox: { 'm-1': MSG }, sent_pending: {},
    }));
    writeFileSync(join(root, 'incoming-spool', 'bob', 's-1.json'), JSON.stringify({ ...MSG, message_id: 's-1' }));
    writeFileSync(join(root, 'archive', 'bob.jsonl'), JSON.stringify({ ...MSG, direction: 'in' }) + '\n');
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    t.after(() => {
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    });
    const bobMailbox = () => readFileSync(join(root, 'mailbox', 'bob.json'), 'utf-8');
    const bobSpool = () => readdirSync(join(root, 'incoming-spool', 'bob'));
    return { bobMailbox, bobSpool, root };
}

const commands = [
    ['mailbox-list', (input, deps) => runApiMailboxList(input, deps)],
    ['mailbox-mark-delivered', async (input, deps) => runApiMailboxMarkDelivered({ ...input, message_id: 'm-1' }, deps)],
    ['archive-lookup', async (input, deps) => runApiArchiveLookup({ ...input, message_id: 'm-1' }, deps)],
];

for (const [name, run] of commands) {
    test(`${name}: a worker cannot act as another worker, and nothing of that worker changes`, async (t) => {
        const s = setup(t);
        const before = [s.bobMailbox(), s.bobSpool()];
        await assert.rejects(run({ team_name: 't1', worker: 'bob' }, { env: { MY_TEAM_WORKER: 't1/alice' } }),
            (err) => err.code === 'forbidden' && /started as 'alice'.*worker "alice"/s.test(err.message));
        assert.deepEqual([s.bobMailbox(), s.bobSpool()], before, 'bob\'s spool is not absorbed, his mail not consumed');
    });

    test(`${name}: a worker of another team cannot name this team`, async (t) => {
        setup(t);
        await assert.rejects(run({ team_name: 't1', worker: 'bob' }, { env: { MY_TEAM_WORKER: 'uu/bob' } }),
            (err) => err.code === 'forbidden' && /team 'uu'/.test(err.message));
    });

    test(`${name}: a worker acts as itself`, async (t) => {
        setup(t);
        const r = await run({ team_name: 't1', worker: 'bob' }, { env: { MY_TEAM_WORKER: 't1/bob' } });
        assert.equal(r.ok, true);
    });

    test(`${name}: without MY_TEAM_WORKER (the user's shell) the input worker stands`, async (t) => {
        setup(t);
        const r = await run({ team_name: 't1', worker: 'bob' }, { env: {} });
        assert.equal(r.ok, true);
    });
}
