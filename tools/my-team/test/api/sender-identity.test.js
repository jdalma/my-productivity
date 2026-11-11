/**
 * The sender of a message is the worker the calling process was started as (T58): a worker's MY_TEAM_WORKER
 * (`<team>/<worker>`) pins from_worker, so a reviewer cannot post as the pm (R56 (b)). A process without the
 * variable (the user's shell) is trusted as before. A guard against mistakes, not authentication.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { runApiSendMessage } from '../../src/commands/api/send-message.js';
import { validateConfig } from '../../src/config/parser.js';

function setup(t) {
    const base = mkdtempSync(join(tmpdir(), 'my-team-identity-'));
    const team = (name, workers) => {
        const stateRoot = join(base, name);
        mkdirSync(join(stateRoot, 'mailbox'), { recursive: true });
        writeFileSync(join(stateRoot, 'manifest.json'), JSON.stringify({
            team_name: name, state_root: stateRoot, session_name: `my-team-${name}-x:0`,
            workers: workers.map(([n, role]) => ({ name: n, role, pane_id: '%999' })),
        }));
        return stateRoot;
    };
    const t1 = team('tt', [['pm', 'orchestrator'], ['rv', 'worker'], ['core', 'worker']]);
    const t2 = team('uu', [['lead', 'orchestrator'], ['dev', 'worker']]);
    process.env.MY_TEAM_STATE_ROOT_BASE = base;
    t.after(() => {
        delete process.env.MY_TEAM_STATE_ROOT_BASE;
        delete process.env.MY_TEAM_STATE_ROOT;
        rmSync(base, { recursive: true, force: true });
    });
    const files = (root) => {
        const out = [];
        const walk = (d) => { for (const n of readdirSync(d, { withFileTypes: true })) n.isDirectory() ? walk(join(d, n.name)) : out.push(join(d, n.name)); };
        walk(root);
        return out.filter((f) => !f.endsWith('manifest.json'));
    };
    const events = (root) => existsSync(join(root, 'events.jsonl'))
        // message lines only: no live pane here, so each send also logs a trigger-refused line (T63e2)
        ? readFileSync(join(root, 'events.jsonl'), 'utf-8').trim().split('\n').map((l) => JSON.parse(l)).filter((e) => e.type === 'message') : [];
    const deps = (env) => ({ env, resolvePaneBySessionWorker: async () => '%999' });
    return { t1, t2, files, events, deps };
}

test('a worker cannot send as another worker: refused before anything is written (a, R56 b)', async (t) => {
    const s = setup(t);
    await assert.rejects(
        runApiSendMessage({ team_name: 'tt', from_worker: 'pm', to_worker: 'core', body: 'x' }, s.deps({ MY_TEAM_WORKER: 'tt/rv' })),
        /started as 'rv'.*from_worker "rv"/s,
    );
    assert.deepEqual(s.files(s.t1), [], 'no spool, archive, mailbox or events: no notification either');
});

test('the same name passes (b), and an omitted from_worker is filled from the environment (c)', async (t) => {
    const s = setup(t);
    const r1 = await runApiSendMessage({ team_name: 'tt', from_worker: 'rv', to_worker: 'core', body: 'b' }, s.deps({ MY_TEAM_WORKER: 'tt/rv' }));
    assert.equal(r1.ok, true);
    const r2 = await runApiSendMessage({ team_name: 'tt', to_worker: 'core', body: 'c' }, s.deps({ MY_TEAM_WORKER: 'tt/rv' }));
    assert.equal(r2.ok, true);
    assert.deepEqual(s.events(s.t1).map((e) => [e.from, e.body]), [['rv', 'b'], ['rv', 'c']]);
});

test('without the variable the input is trusted as before; from_worker is then required (d)', async (t) => {
    const s = setup(t);
    const r = await runApiSendMessage({ team_name: 'tt', from_worker: 'pm', to_worker: 'core', body: 'd' }, s.deps({}));
    assert.equal(r.ok, true);
    assert.equal(s.events(s.t1)[0].from, 'pm');
    await assert.rejects(runApiSendMessage({ team_name: 'tt', to_worker: 'core', body: 'd' }, s.deps({})), /from_worker is required/);
});

test('a worker of another team cannot send as a member of this one', async (t) => {
    const s = setup(t);
    await assert.rejects(
        runApiSendMessage({ team_name: 'tt', from_worker: 'pm', to_worker: 'core', body: 'x' }, s.deps({ MY_TEAM_WORKER: 'uu/lead' })),
        /team 'uu'.*team_name "uu"/s,
    );
    assert.deepEqual(s.files(s.t1), []);
});

test('cross-team sends work as before, from the sender\'s own team (f)', async (t) => {
    const s = setup(t);
    process.env.MY_TEAM_STATE_ROOT = s.t1;
    const r = await runApiSendMessage({ team_name: 'tt', from_worker: 'pm', to_team: 'uu', to_worker: 'lead', body: 'f' },
        s.deps({ MY_TEAM_WORKER: 'tt/pm' }));
    assert.equal(r.ok, true);
    assert.equal(r.delivered_to_team, 'uu');
    assert.deepEqual(s.events(s.t2).map((e) => [e.from, e.from_team]), [['pm', 'tt']]);
    await assert.rejects(
        runApiSendMessage({ team_name: 'tt', from_worker: 'pm', to_team: 'uu', to_worker: 'lead', body: 'f' }, s.deps({ MY_TEAM_WORKER: 'tt/rv' })),
        /started as 'rv'/,
    );
});

test('a config cannot set a worker\'s identity variables (e)', () => {
    const cwd = mkdtempSync(join(tmpdir(), 'my-team-identity-cfg-'));
    try {
        for (const key of ['MY_TEAM_WORKER', 'OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT']) {
            assert.throws(() => validateConfig({ team_name: 'ee', workers: [{ name: 'a', agent_type: 'claude', cwd, env: { [key]: 'e/pm' } }] }),
                new RegExp(`env\\.${key}.*set by my-team`), key);
        }
        assert.doesNotThrow(() => validateConfig({ team_name: 'ee', workers: [{ name: 'a', agent_type: 'claude', cwd, env: { FOO: 'bar' } }] }));
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
});

test('a message delivered but not logged is still ok, with a warning, and delivered once (T62, R61 L1)', async (t) => {
    const s = setup(t);
    for (const appendMessageEvent of [
        async () => { throw new Error("events: 'message' has no key oops"); },   // a shape mistake in a future change
        async () => false,                                                        // the file could not be written
    ]) {
        const r = await runApiSendMessage({ team_name: 'tt', from_worker: 'rv', to_worker: 'core', body: 'once' },
            { ...s.deps({ MY_TEAM_WORKER: 'tt/rv' }), appendMessageEvent });
        assert.equal(r.ok, true);
        assert.match(r.warning, /events\.jsonl/);
    }
    const spooled = s.files(s.t1).filter((f) => f.includes('incoming-spool'));
    assert.equal(spooled.length, 2, 'one spool file per send, none resent');
});
