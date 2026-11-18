/**
 * Unit tests for the worker `description` field in config parsing.
 *
 * `description` is an optional free-text one-liner shown to *other* workers
 * in the Team Roster, so a worker LLM can decide whom to ask for help.
 * Distinct from `extra_prompt` (the worker's own detailed instructions).
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import { validateConfig } from '../../src/config/parser.js';

function baseConfig(workerOverrides = {}) {
    const cwd = mkdtempSync(join(tmpdir(), 'my-team-cfg-'));
    return {
        cwd,
        cfg: {
            team_name: 'cfg-test',
            workers: [
                { name: 'alice', cwd, agent_type: 'claude', ...workerOverrides },
            ],
        },
    };
}

test('description is parsed when provided', () => {
    const { cwd, cfg } = baseConfig({ description: 'Backend payment API expert.' });
    try {
        const result = validateConfig(cfg);
        assert.equal(result.workers[0].description, 'Backend payment API expert.');
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
});

test('description defaults to empty string when absent', () => {
    const { cwd, cfg } = baseConfig({});
    try {
        const result = validateConfig(cfg);
        assert.equal(result.workers[0].description, '');
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
});

test('description rejects non-string value', () => {
    const { cwd, cfg } = baseConfig({ description: 123 });
    try {
        assert.throws(() => validateConfig(cfg), /description must be a string/);
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
});

test('whitespace-only description normalizes to empty string', () => {
    const { cwd, cfg } = baseConfig({ description: '   \n  ' });
    try {
        const result = validateConfig(cfg);
        assert.equal(result.workers[0].description, '');
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
});

test('description coexists with extra_prompt independently', () => {
    const { cwd, cfg } = baseConfig({
        description: 'One-line summary for peers.',
        extra_prompt: 'Detailed multi-line instructions for this worker itself.',
    });
    try {
        const result = validateConfig(cfg);
        assert.equal(result.workers[0].description, 'One-line summary for peers.');
        assert.equal(result.workers[0].extra_prompt, 'Detailed multi-line instructions for this worker itself.');
    } finally {
        rmSync(cwd, { recursive: true, force: true });
    }
});
