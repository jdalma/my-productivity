/**
 * The protocol reload (lib/protocol-reload.js): after a context compaction a claude worker's SessionStart hooks
 * print its AGENTS.md again, in parts under the limit Claude Code cuts one hook's output at.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { partText, protocolReloadHook, splitProtocol } from '../../src/lib/protocol-reload.js';
import { generateWorkerOverlay } from '../../src/lib/worker-bootstrap.js';

const HOOK_OUTPUT_LIMIT = 10000; // Claude Code's, per hook

const roster = [
    { name: 'pm', agentType: 'claude', role: 'PM', teamRole: 'orchestrator' },
    { name: 'dev', agentType: 'claude', role: 'dev', teamRole: 'worker' },
];
// the longest AGENTS.md there is: an orchestrator of a board team, with a brief
const overlay = generateWorkerOverlay({
    teamName: 'demo', workerName: 'pm', agentType: 'claude', workerRole: 'orchestrator', teamRoster: roster,
    bootstrapInstructions: '한글 브리프 '.repeat(200), instructionStateRoot: '/s/demo', board: { store: 'sqlite' },
});

test('the parts are whole lines, put back together they are the file, and each printed part is under the hook limit', () => {
    const parts = splitProtocol(overlay);
    assert.ok(parts.length >= 3, `an orchestrator's AGENTS.md needs several parts (${parts.length})`);
    assert.equal(parts.join('\n'), overlay);
    parts.forEach((_, i) => {
        const text = partText('/s/demo/workers/pm/AGENTS.md', overlay, i + 1);
        assert.ok(text.length < HOOK_OUTPUT_LIMIT, `part ${i + 1} is ${text.length} characters`);
        assert.match(text, new RegExp(`^my-team worker protocol, part ${i + 1} of ${parts.length}, from /s/demo/workers/pm/AGENTS\\.md\\. This conversation was compacted`));
        assert.ok(text.includes(parts[i]));
    });
    assert.equal(partText('/p', overlay, parts.length + 1), '', 'past the last part: nothing');
    assert.equal(partText('/p', overlay, 0), '');
    assert.equal(partText('/p', '', 1), '', 'an empty file: nothing');
    assert.deepEqual(splitProtocol('one\ntwo'), ['one\ntwo'], 'a short file is one part');
    assert.deepEqual(splitProtocol(''), []);

    // blank lines at a part's edge and at the file's ends are lines like any other
    for (const text of ['\n\nx\n', `${'x'.repeat(8999)}\n\n\ny`, `a\n${'x'.repeat(8990)}\n\n\n\nb\n`]) {
        assert.equal(splitProtocol(text).join('\n'), text);
    }
});

test('a line longer than a part (an extra_prompt written as one line) is cut into pieces, none of them over the hook limit', () => {
    const long = generateWorkerOverlay({
        teamName: 'demo', workerName: 'dev', agentType: 'claude', workerRole: 'worker', teamRoster: roster,
        bootstrapInstructions: '한 줄로 쓴 긴 브리프. '.repeat(1700), instructionStateRoot: '/s/demo',
    });
    assert.ok(long.split('\n').some((line) => line.length > 20000));
    const parts = splitProtocol(long);
    parts.forEach((_, i) => assert.ok(partText('/s/demo/workers/dev/AGENTS.md', long, i + 1).length < HOOK_OUTPUT_LIMIT, `part ${i + 1}`));
    assert.equal(parts.join('').replaceAll('\n', ''), long.replaceAll('\n', ''), 'no character is lost');

    const emoji = splitProtocol('😀'.repeat(9500));
    assert.ok(emoji.every((part) => part.length <= 9000 && part.isWellFormed()), 'the limit is in UTF-16 units, and no character is cut in two');
    assert.equal(emoji.join(''), '😀'.repeat(9500));
});

test('the settings entry runs after a compaction only, with one command per part', () => {
    const entry = protocolReloadHook("/s/it's/AGENTS.md", overlay);
    assert.equal(entry.matcher, 'compact');
    assert.equal(entry.hooks.length, splitProtocol(overlay).length);
    entry.hooks.forEach((h, i) => {
        assert.equal(h.type, 'command');
        assert.match(h.command, /^node '[^']*worker-protocol-hook\.js' --file /);
        assert.ok(h.command.endsWith(` --part ${i + 1}`));
    });
    assert.ok(entry.hooks[0].command.includes(`'/s/it'\\''s/AGENTS.md'`), 'the path is quoted for the shell');
});

test('the hook, run as Claude Code runs it, prints its part of the file; a file it cannot read prints nothing and does not fail', (t) => {
    const dir = mkdtempSync(join(tmpdir(), "mt-reload it's-"));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const file = join(dir, 'AGENTS.md');
    writeFileSync(file, overlay);
    const entry = protocolReloadHook(file, overlay);
    const outputs = entry.hooks.map((h) => spawnSync('sh', ['-c', h.command], { encoding: 'utf-8' }));
    outputs.forEach((run, i) => {
        assert.equal(run.status, 0, run.stderr);
        assert.equal(run.stdout, partText(file, overlay, i + 1));
    });
    assert.equal(outputs.map((run) => run.stdout.split('\n\n').slice(1).join('\n\n').replace(/\n$/, '')).join('\n'), overlay, 'all of the file comes back');

    const gone = spawnSync('sh', ['-c', protocolReloadHook(join(dir, 'none.md'), overlay).hooks[0].command], { encoding: 'utf-8' });
    assert.equal(gone.status, 0);
    assert.equal(gone.stdout, '');
});
