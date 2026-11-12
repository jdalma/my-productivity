/**
 * Team knowledge in the AGENTS.md overlay (T68): a team's shared documents, by path and one line about each,
 * in every worker's instructions; the documents themselves are not copied. A team without them gets the
 * overlay it had before, to the byte. Example paths only (example.com family).
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { generateWorkerOverlay } from '../../src/lib/worker-bootstrap.js';
import { startupNotice } from '../../src/lib/startup-notice.js';

const roster = [
    { name: 'pm', agentType: 'claude', role: 'PM', teamRole: 'orchestrator' },
    { name: 'dev', agentType: 'claude', role: 'dev', teamRole: 'worker' },
];
const KNOWLEDGE = [
    { path: '/docs/example.com/cloud-guide.md', about: 'cloud lookups and the protection policy; read before any cloud CLI' },
    { path: '/docs/example.com/db-guide.md', about: 'database connection profiles; read before querying a database' },
];
const overlay = (workerName, workerRole, extra = {}) => generateWorkerOverlay({
    teamName: 'demo', workerName, agentType: 'claude', workerRole, teamRoster: workerRole ? roster : [],
    bootstrapInstructions: 'brief', instructionStateRoot: '/s/demo', ...extra,
});

test('(a) a team without knowledge: no section, and knowledge null or empty renders the same overlay', () => {
    for (const [w, role] of [['pm', 'orchestrator'], ['dev', 'worker'], ['solo', null]]) {
        const plain = overlay(w, role);
        assert.equal(overlay(w, role, { knowledge: null }), plain);
        assert.equal(overlay(w, role, { knowledge: [] }), plain);
        assert.doesNotMatch(plain, /Team Knowledge/);
    }
});

test('(b) every worker of a team with knowledge gets the section: each path and what it is about, not the documents', () => {
    for (const [w, role] of [['pm', 'orchestrator'], ['dev', 'worker'], ['solo', null]]) {
        const text = overlay(w, role, { knowledge: KNOWLEDGE });
        assert.match(text, /\n## Team Knowledge\n/, w);
        for (const k of KNOWLEDGE) {
            assert.ok(text.includes(k.path), `${w}: ${k.path}`);
            assert.ok(text.includes(k.about), `${w}: ${k.about}`);
        }
        assert.match(text, /read (that|the) document/i, w);
    }
});

test('(e) under --continue, knowledge that changed shows in the startup notice\'s changed sections', () => {
    const before = overlay('dev', 'worker', { knowledge: KNOWLEDGE });
    const fewer = overlay('dev', 'worker', { knowledge: KNOWLEDGE.slice(0, 1) });
    const none = overlay('dev', 'worker');
    const n = (previous, current) => startupNotice({ overlayPath: '/s/demo/workers/dev/AGENTS.md', keep: true, previous, current,
        agentType: 'claude', launchArgs: ['--resume', 'x'], mail: { spool: 0, unread: 0 } });
    assert.match(n(before, fewer), /changed: Team Knowledge/);
    assert.match(n(none, before), /added: Team Knowledge/);
    assert.match(n(before, none), /removed: Team Knowledge/);
    assert.equal(n(before, before), null);
});
