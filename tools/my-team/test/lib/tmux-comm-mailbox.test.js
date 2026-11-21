/**
 * Mailbox durability: spool absorption must not lose a message when the mailbox write fails, and
 * concurrent processes writing one worker's mailbox must not lose each other's updates.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, existsSync, rmSync } from 'fs';
import { spawn } from 'child_process';
import { tmpdir } from 'os';
import { join } from 'path';
import { pathToFileURL } from 'url';

import { absorbIncomingSpool, MAILBOX_SCHEMA_VERSION } from '../../src/lib/tmux-comm.js';

function setupTeam(teamName = 't1') {
    const base = mkdtempSync(join(tmpdir(), 'my-team-test-'));
    const stateRoot = join(base, teamName);
    mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    return { base, stateRoot, teamName };
}

function cleanup(ctx) {
    delete process.env.MY_TEAM_STATE_ROOT_BASE;
    rmSync(ctx.base, { recursive: true, force: true });
}

function dropSpool(ctx, worker, id) {
    const dir = join(ctx.stateRoot, 'incoming-spool', worker);
    mkdirSync(dir, { recursive: true });
    const file = join(dir, `${id}.json`);
    writeFileSync(file, JSON.stringify({
        message_id: id, from_worker: 'alice', to_worker: worker, body: `body ${id}`,
        reply_to: null, expects_reply: false, created_at: new Date().toISOString(),
    }));
    return file;
}

test('E3: a spool file survives when the mailbox write fails', async () => {
    const ctx = setupTeam();
    try {
        const spool = dropSpool(ctx, 'bob', 'm1');
        // A non-empty directory where bob.json belongs makes the rename in atomicWriteJson fail.
        mkdirSync(join(ctx.stateRoot, 'mailbox', 'bob.json', 'blocker'), { recursive: true });

        await assert.rejects(absorbIncomingSpool(ctx.teamName, 'bob', ctx.base));
        assert.ok(existsSync(spool), 'spool file must remain until the mailbox write succeeds');
    } finally {
        cleanup(ctx);
    }
});

const PROCS = 6;
const ROUNDS = 25;
const commUrl = pathToFileURL(join(import.meta.dirname, '../../src/lib/tmux-comm.js')).href;
const markUrl = pathToFileURL(join(import.meta.dirname, '../../src/commands/api/mailbox-mark-delivered.js')).href;

// Each child marks its own inbox entries, records its own sent_pending entries, and absorbs the shared
// spool, all on bob's one mailbox, starting at the same instant as its siblings.
const childSource = `
import { absorbIncomingSpool, queueDirectMessage } from ${JSON.stringify(commUrl)};
import { runApiMailboxMarkDelivered } from ${JSON.stringify(markUrl)};
const [team, base, proc, rounds, startAt] = process.argv.slice(1);
while (Date.now() < Number(startAt)) { /* spin so siblings collide */ }
for (let j = 0; j < Number(rounds); j++) {
    runApiMailboxMarkDelivered({ team_name: team, worker: 'bob', message_id: 'in-' + proc + '-' + j });
    await queueDirectMessage(team, 'bob', 'alice', 'q ' + proc + '-' + j, null, base, null, true);
    await absorbIncomingSpool(team, 'bob', base);
}
`;

function runChild(args) {
    return new Promise((resolve) => {
        const child = spawn(process.execPath, ['--input-type=module', '-e', childSource, ...args], {
            env: { ...process.env, MY_TEAM_STATE_ROOT_BASE: args[1] },
            stdio: ['ignore', 'ignore', 'pipe'],
        });
        let stderr = '';
        child.stderr.on('data', (d) => { stderr += d; });
        child.on('exit', (code) => resolve({ code, stderr }));
    });
}

test('E4: processes racing on one mailbox lose no inbox, sent_pending, or spool update', async () => {
    const ctx = setupTeam();
    try {
        writeFileSync(join(ctx.stateRoot, 'manifest.json'), JSON.stringify({
            team_name: ctx.teamName, state_root: ctx.stateRoot,
            workers: [{ name: 'alice', pane_id: '%0' }, { name: 'bob', pane_id: '%0' }],
        }));
        const inbox = {};
        const spoolIds = [];
        for (let p = 0; p < PROCS; p++) {
            for (let j = 0; j < ROUNDS; j++) {
                const id = `in-${p}-${j}`;
                inbox[id] = { message_id: id, from_worker: 'alice', to_worker: 'bob', body: id, created_at: 'x' };
                spoolIds.push(`sp-${p}-${j}`);
                dropSpool(ctx, 'bob', `sp-${p}-${j}`);
            }
        }
        const mailboxFile = join(ctx.stateRoot, 'mailbox', 'bob.json');
        writeFileSync(mailboxFile, JSON.stringify({ schema_version: MAILBOX_SCHEMA_VERSION, worker: 'bob', inbox, sent_pending: {} }));

        const startAt = String(Date.now() + 1500);
        const results = await Promise.all(
            Array.from({ length: PROCS }, (_, p) => runChild([ctx.teamName, ctx.base, String(p), String(ROUNDS), startAt])),
        );
        for (const r of results) assert.equal(r.code, 0, r.stderr);

        const mailbox = JSON.parse(readFileSync(mailboxFile, 'utf-8'));
        assert.deepEqual(Object.keys(mailbox.inbox).sort(), spoolIds.sort(), 'inbox holds exactly the absorbed spool messages');
        assert.equal(Object.keys(mailbox.sent_pending).length, PROCS * ROUNDS, 'every sent_pending entry survives');
        assert.deepEqual(readdirSync(join(ctx.stateRoot, 'incoming-spool', 'bob')), [], 'spool drained');
        assert.ok(!existsSync(`${mailboxFile}.lock`), 'lock released');
    } finally {
        cleanup(ctx);
    }
});
