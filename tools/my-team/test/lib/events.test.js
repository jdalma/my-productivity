/**
 * One line format for events.jsonl (T60): every new line carries ts, type, team and worker (who acted),
 * only the keys its type lists, and bounded free text. Old lines (no type, session keys) read back in the
 * same shape. The files themselves are never rewritten.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { fileURLToPath } from 'url';

import { appendEvent, appendMessageEvent, eventLine, readEvent, TEXT_LIMIT } from '../../src/lib/events.js';

const MY_TEAM = fileURLToPath(new URL('../../bin/my-team', import.meta.url));

function lines(root) {
    return readFileSync(join(root, 'events.jsonl'), 'utf-8').trim().split('\n').map((l) => JSON.parse(l));
}

test('every kind of line carries ts, type, team and worker (a)', async (t) => {
    const root = mkdtempSync(join(tmpdir(), 'mt-events-'));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    await appendMessageEvent(root, { team: 'tt', from: 'pm', to: 'core', body: 'hi', message_id: 'm1', reply_to: null, expects_reply: false });
    await appendEvent(root, { type: 'tmux-denied', team: 'tt', worker: 'rv', args: ['kill-server'] });
    await appendEvent(root, { type: 'tool-denied', team: 'tt', worker: 'rv', tool: 'Bash', rule: 'push', target: 'git push' });
    const [m, x, y] = lines(root);
    for (const e of [m, x, y]) {
        assert.ok(!Number.isNaN(Date.parse(e.ts)), JSON.stringify(e));
        assert.equal(e.team, 'tt');
        assert.ok(e.worker);
    }
    assert.deepEqual([m.type, x.type, y.type], ['message', 'tmux-denied', 'tool-denied']);
    assert.deepEqual([m.worker, m.from, m.to], ['pm', 'pm', 'core'], 'a message keeps from/to; worker is its sender');
});

test('a key the format does not list is an error, and so is a missing one (b)', () => {
    assert.throws(() => eventLine({ type: 'tool-denied', team: 'tt', worker: 'rv', tool: 'Bash', rule: 'push', target: 'x', extra: 1 }), /extra/);
    assert.throws(() => eventLine({ type: 'message', team: 'tt', worker: 'pm', from: 'pm', to: 'core', body: 'x', message_id: 'm', reply_to: null, expects_reply: false, to_session: 's' }), /to_session/);
    assert.throws(() => eventLine({ type: 'tool-denied', team: 'tt', worker: 'rv', tool: 'Bash', rule: 'push' }), /target/);
    assert.throws(() => eventLine({ type: 'party', team: 'tt', worker: 'rv' }), /party/);
});

test('v1, session-keyed, mirrored and new lines read back in one shape (c)', () => {
    const base = { ts: '2026-11-11T00:00:00.000Z' };
    const v1 = readEvent({ ...base, from: 'pm', to: 'core', body: 'b' }, 'tt');
    const session = readEvent({ ...base, type: 'message', from: 'pm', to: 'lead', body: 'b', message_id: 'm', reply_to: null,
        expects_reply: false, from_session: 'my-team-tt-x', to_session: 'my-team-uu-y', to_team: 'uu' }, 'tt');
    const mirror = readEvent({ ...base, type: 'message', from: 'pm', to: 'lead', body: 'b', message_id: 'm', reply_to: null,
        expects_reply: false, from_team: 'tt', to_team: 'uu' }, 'uu');
    const fresh = readEvent(eventLine({ type: 'message', team: 'tt', worker: 'pm', from: 'pm', to: 'core', body: 'b',
        message_id: 'm', reply_to: null, expects_reply: false }), 'tt');
    const shape = (e) => ['ts', 'type', 'team', 'worker', 'from', 'to', 'body', 'message_id', 'reply_to', 'expects_reply'].map((k) => [k, k in e]);
    for (const e of [v1, session, mirror, fresh]) {
        assert.deepEqual(shape(e), shape(fresh), JSON.stringify(e));
        assert.equal(e.type, 'message');
        assert.equal(e.worker, 'pm');
    }
    assert.deepEqual([v1.message_id, v1.reply_to, v1.expects_reply], [null, null, false]);
    assert.equal(mirror.team, 'tt', 'a mirrored line was written by the sender\'s team');
    assert.equal(session.to_session, 'my-team-uu-y', 'old optional keys stay readable');
    const denied = readEvent({ ...base, type: 'tmux-denied', team: 'tt', worker: 'rv', args: ['ls'] }, 'xx');
    assert.deepEqual([denied.team, denied.worker], ['tt', 'rv']);
});

test(`free text past ${TEXT_LIMIT} characters is cut, saying how much (d)`, () => {
    const long = 'x'.repeat(TEXT_LIMIT + 300);
    const e = eventLine({ type: 'tmux-denied', team: 'tt', worker: 'rv', args: ['send-keys', '-l', long] });
    assert.equal(e.args[1], '-l');
    assert.ok(e.args[2].length < long.length);
    assert.match(e.args[2], /…\[\+300 chars\]$/);
    const many = eventLine({ type: 'tmux-denied', team: 'tt', worker: 'rv', args: Array.from({ length: 100 }, (_, i) => `a${i}`) });
    assert.ok(JSON.stringify(many.args).length <= TEXT_LIMIT * 2, 'the whole list is bounded too');
    assert.match(many.args.at(-1), /^…\[\+\d+ args\]$/);
    const tool = eventLine({ type: 'tool-denied', team: 'tt', worker: 'rv', tool: 'Bash', rule: 'push', target: long });
    assert.match(tool.target, /…\[\+300 chars\]$/);
    const msg = eventLine({ type: 'message', team: 'tt', worker: 'pm', from: 'pm', to: 'core', body: long, message_id: 'm', reply_to: null, expects_reply: false });
    assert.equal(msg.body, long, 'a message body is the message itself and stays whole');
});

test('monitor prints old and new lines without undefined (e)', (t) => {
    const base = mkdtempSync(join(tmpdir(), 'mt-events-mon-'));
    t.after(() => rmSync(base, { recursive: true, force: true }));
    const root = join(base, 'tt');
    mkdirSync(root);
    writeFileSync(join(root, 'manifest.json'), JSON.stringify({ team_name: 'tt', state_root: root, workers: [] }));
    const old = [
        { ts: '2026-11-11T00:00:00.000Z', from: 'pm', to: 'core', body: 'v1' },
        { ts: '2026-11-11T00:00:01.000Z', type: 'message', from: 'pm', to: 'lead', body: 'xs', message_id: 'm', reply_to: null, expects_reply: false, from_session: 's', to_session: 'u', to_team: 'uu' },
        eventLine({ type: 'tmux-denied', team: 'tt', worker: 'rv', args: ['kill-server'] }),
        eventLine({ type: 'tool-denied', team: 'tt', worker: 'rv', tool: 'Bash', rule: 'push', target: 'git push' }),
    ];
    writeFileSync(join(root, 'events.jsonl'), old.map((e) => JSON.stringify(e)).join('\n') + '\n');
    // monitor watches forever: read its first output, then stop it
    let out = '';
    try {
        out = execFileSync(process.execPath, [MY_TEAM, 'monitor', 'tt', '--state-root', root], {
            env: { PATH: process.env.PATH, HOME: process.env.HOME, MY_TEAM_STATE_ROOT_BASE: base }, encoding: 'utf-8', timeout: 3000,
        });
    } catch (e) { out = e.stdout ?? ''; }
    assert.match(out, /pm → core/);
    assert.match(out, /tmux kill-server/);
    assert.match(out, /Bash.*git push/);
    assert.doesNotMatch(out, /undefined/);
});
