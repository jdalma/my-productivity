/**
 * The notice `my-team start` types into each worker's pane (T66). A new team, or a worker that does not carry
 * its conversation over, gets the full notice. A worker that resumes its conversation under `--continue` and
 * finds its AGENTS.md unchanged gets nothing, or one line about waiting mail; one whose AGENTS.md changed gets
 * one line naming the sections that changed. Panes on a tmux server of this file's own.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { continuesConversation, sectionChanges, sendStartupNotices, startupNotice } from '../../src/lib/startup-notice.js';
import { tmuxExec } from '../../src/lib/tmux-utils.js';

if (process.env.MY_TEAM_TEST_TMUX) {
    const own = `${process.env.MY_TEAM_TEST_TMUX}-notice`;
    process.env.MY_TEAM_TEST_TMUX = own;
    test.after(() => {
        try { tmuxExec(['kill-server'], { stdio: 'pipe' }); } catch { /* none */ }
        rmSync(`/tmp/tmux-${process.getuid()}/${own}`, { force: true });
    });
}

const PATH = '/s/team/workers/core/AGENTS.md';
const OVERLAY = '# Team Worker Protocol\n\nintro\n\n## Identity\n- core\n\n## Rules\n- one\n';
const RESUMED = ['--dangerously-skip-permissions', '--resume', 'abc'];
const full = (s) => /^Team is live\. Follow \/s\/team\/workers\/core\/AGENTS\.md for the peer protocol/.test(s ?? '');
const notice = (over) => startupNotice({ overlayPath: PATH, keep: true, previous: OVERLAY, current: OVERLAY,
    agentType: 'claude', launchArgs: RESUMED, mail: { spool: 0, unread: 0 }, ...over });

test('(a) --continue, the same AGENTS.md, no mail, a resumed conversation: no notice', () => {
    assert.equal(notice({}), null);
});

test('(b) the same AGENTS.md with mail waiting: one line to read the mailbox', () => {
    const line = notice({ mail: { spool: 2, unread: 1 } });
    assert.match(line, /mailbox/);
    assert.match(line, /3 /);
    assert.doesNotMatch(line, /\n/);
    assert.equal(full(line), false);
});

test('(c) a changed AGENTS.md: one line naming the sections added, changed and removed', () => {
    const current = '# Team Worker Protocol\n\nintro\n\n## Identity\n- core\n\n## Rules\n- one\n- two\n\n## Team Board\n- board\n';
    const line = notice({ previous: OVERLAY.replace('## Identity\n- core\n\n', '## Identity\n- core\n\n## Broadcast caveat\n- x\n\n'), current });
    assert.match(line, /changed/i);
    assert.match(line, /added: Team Board/);
    assert.match(line, /changed: Rules/);
    assert.match(line, /removed: Broadcast caveat/);
    assert.match(line, new RegExp(PATH.replaceAll('/', '\\/')));
    assert.doesNotMatch(line, /\n/);
    assert.match(notice({ previous: OVERLAY, current, mail: { spool: 1, unread: 0 } }), /1 [^\n]*mailbox/, 'mail is mentioned too');
});

test('(d) no AGENTS.md before (a new worker, or no state): the full notice', () => {
    assert.equal(full(notice({ previous: null })), true);
});

test('(e) a start without --continue: the full notice', () => {
    assert.equal(full(notice({ keep: false })), true);
});

test('(f) a worker that does not carry its conversation over gets the full notice, even with --continue', () => {
    assert.equal(full(notice({ launchArgs: ['--dangerously-skip-permissions'] })), true, 'claude without --resume');
    assert.equal(full(notice({ agentType: 'codex', launchArgs: ['resume', 'abc'] })), true, 'codex: cannot tell, so the full notice');
    assert.equal(full(notice({ previous: OVERLAY + '\n## New\n', launchArgs: [] })), true, 'changed and not resumed: it reads it whole');
});

test('which launches carry a claude conversation over', () => {
    for (const args of [['--resume', 'x'], ['-r', 'x'], ['--resume=x'], ['--continue'], ['-c'], ['--dangerously-skip-permissions', '--resume', 'x']]) {
        assert.equal(continuesConversation('claude', args), true, args.join(' '));
    }
    for (const [type, args] of [['claude', []], ['claude', ['--session-id', 'u']], ['claude', ['--fork-session']], ['codex', ['--resume', 'x']], ['gemini', ['-c']]]) {
        assert.equal(continuesConversation(type, args), false, `${type} ${args.join(' ')}`);
    }
});

test('sectionChanges: by "## " section; a "###" belongs to its section; text before the first section is the top', () => {
    const a = '# T\ntop\n## A\na\n### A1\nx\n## B\nb\n';
    assert.deepEqual(sectionChanges(a, a), { added: [], changed: [], removed: [] });
    assert.deepEqual(sectionChanges(a, a.replace('x\n', 'y\n')), { added: [], changed: ['A'], removed: [] });
    assert.deepEqual(sectionChanges(a, a.replace('top', 'TOP')), { added: [], changed: ['(top)'], removed: [] });
    assert.deepEqual(sectionChanges(a, a.replace('## B\nb\n', '## C\nc\n')), { added: ['C'], changed: [], removed: ['B'] });
});

test('sendStartupNotices types each notice into its pane and nothing into a pane whose notice is null', async (t) => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'mt-notice-')));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const session = `notice-${process.pid}`;
    const sink = (log) => `while IFS= read -r l; do printf '%s\\n' "$l" >> '${log}'; printf '\\033[1A\\033[2K'; done`;
    tmuxExec(['new-session', '-d', '-s', session, sink(join(dir, 'a'))], { stdio: 'pipe' });
    t.after(() => { try { tmuxExec(['kill-session', '-t', session], { stdio: 'pipe' }); } catch { /* gone */ } });
    const a = tmuxExec(['display-message', '-p', '-t', session, '#{pane_id}'], { stdio: 'pipe' }).trim();
    const b = tmuxExec(['split-window', '-d', '-P', '-F', '#{pane_id}', '-t', session, sink(join(dir, 'b'))], { stdio: 'pipe' }).trim();
    const lines = (f) => (existsSync(join(dir, f)) ? readFileSync(join(dir, f), 'utf-8').split('\n').filter(Boolean) : []);

    const undelivered = await sendStartupNotices(session, [{ name: 'a', pane_id: a, notice: 'hello a' }, { name: 'b', pane_id: b, notice: null }]);
    assert.deepEqual(undelivered, []);
    assert.deepEqual(lines('a'), ['hello a']);
    assert.deepEqual(lines('b'), [], 'nothing typed where there is nothing to say');
});

test('(T66a, R2 L2) many changed sections still make one line within the send limit, and it reaches the pane', async (t) => {
    const many = (n, body) => Array.from({ length: n }, (_, i) => `## A rather long section title number ${i} for the overlay\n${body}\n`).join('');
    const line = notice({ previous: `# T\n${many(30, 'old')}`, current: `# T\n${many(30, 'new')}` });
    assert.ok(line.length <= 500, `${line.length} characters`);
    assert.match(line, /and \d+ more/);
    assert.doesNotMatch(line, /\n/);
    const longPath = startupNotice({ overlayPath: `/${'p'.repeat(480)}/AGENTS.md`, keep: true, previous: '## A\na\n', current: '## A\nb\n',
        agentType: 'claude', launchArgs: RESUMED, mail: { spool: 0, unread: 0 } });
    assert.ok(longPath.length <= 500 || longPath.startsWith('Team is live.'), 'when even one title does not fit: the full notice');

    const dir = realpathSync(mkdtempSync(join(tmpdir(), 'mt-notice-long-')));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const session = `notice-long-${process.pid}`;
    const log = join(dir, 'typed');
    tmuxExec(['new-session', '-d', '-s', session, `while IFS= read -r l; do printf '%s\\n' "$l" >> '${log}'; printf '\\033[1A\\033[2K'; done`], { stdio: 'pipe' });
    t.after(() => { try { tmuxExec(['kill-session', '-t', session], { stdio: 'pipe' }); } catch { /* gone */ } });
    const pane = tmuxExec(['display-message', '-p', '-t', session, '#{pane_id}'], { stdio: 'pipe' }).trim();
    assert.deepEqual(await sendStartupNotices(session, [{ name: 'core', pane_id: pane, notice: line }]), []);
    assert.deepEqual(readFileSync(log, 'utf-8').split('\n').filter(Boolean), [line]);
});
