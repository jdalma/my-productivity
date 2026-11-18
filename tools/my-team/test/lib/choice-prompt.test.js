/**
 * paneHasChoicePrompt + spawnWorkerInPane guard: never let a startup keystroke
 * answer a question the pane is asking. Fixtures are real captures from two
 * incidents: an oh-my-zsh update y/n prompt that ate the start command's first
 * quote, and a Codex update menu whose default ("1. Update now") a startup
 * Enter selected.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { paneHasChoicePrompt, spawnWorkerInPane } from '../../src/lib/tmux-session.js';

const OMZ_YN = `
Last login: Sun Nov  1 23:10:26 on ttys004
[oh-my-zsh] Would you like to update? [Y/n]
`;

const CODEX_UPDATE_MENU = `
  ✨ Update available! 0.153.4 -> 0.165.0

  Release notes: https://github.com/openai/codex/releases/latest

› 1. Update now (runs \`npm install -g @openai/codex\`)
  2. Skip
  3. Skip until next version

`;

const PERMISSION_MODAL = `
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, allow reading from tmp/ during this session
   3. No

 Esc to cancel · Tab to amend
`;

const CLAUDE_IDLE = `
⏺ 정리했습니다:
  1. 첫 번째 항목
  2. 두 번째 항목

────────────────────────────────────────
❯
────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)
`;

const CODEX_IDLE = `
  Worked for 20s • 11:18 PM

› Ask Codex to do anything

  GPT-6-Astra medium · ~/IdeaProjects/demo · Awaiting
`;

const YN_IN_SCROLLBACK = `
[oh-my-zsh] Would you like to update? [Y/n] n
[oh-my-zsh] You can update manually by running \`omz update\`
 ~/IdeaProjects/demo  main $
`;

const SHELL_PROMPT = ` ~/IdeaProjects/demo  main $ `;

test('detects a shell y/n prompt on the last line', () => {
    assert.equal(paneHasChoicePrompt(OMZ_YN), true);
});

test('detects a CLI update menu with a highlighted first option', () => {
    assert.equal(paneHasChoicePrompt(CODEX_UPDATE_MENU), true);
});

test('permission modal is also a choice prompt (callers check it first)', () => {
    assert.equal(paneHasChoicePrompt(PERMISSION_MODAL), true);
});

test('idle Claude / Codex input lines are not prompts', () => {
    assert.equal(paneHasChoicePrompt(CLAUDE_IDLE), false);
    assert.equal(paneHasChoicePrompt(CODEX_IDLE), false);
});

test('an already-answered y/n in scrollback is not a prompt', () => {
    assert.equal(paneHasChoicePrompt(YN_IN_SCROLLBACK), false);
});

const CONFIG = { teamName: 'demo', workerName: 'w1', launchBinary: 'claude', launchArgs: [], envVars: {} };

function fakePane(frames) {
    let i = 0;
    const sent = [];
    return {
        sent,
        capturePane: async () => frames[Math.min(i++, frames.length - 1)],
        tmuxExec: async (args) => { sent.push(args); return { stdout: '' }; },
    };
}

const FAST = { pollIntervalMs: 5, settleTimeoutMs: 200, promptTimeoutMs: 60 };

test('spawnWorkerInPane types the command once the shell prompt settles', async () => {
    const pane = fakePane(['', SHELL_PROMPT, SHELL_PROMPT]);
    const ok = await spawnWorkerInPane('', '%1', CONFIG, { ...pane, ...FAST });
    assert.equal(ok, true);
    assert.equal(pane.sent.length, 2);
    assert.match(pane.sent[0].join(' '), /'claude'/);
    assert.deepEqual(pane.sent[1], ['send-keys', '-t', '%1', 'Enter']);
});

test('spawnWorkerInPane waits for a y/n prompt to be answered before typing', async () => {
    const pane = fakePane([OMZ_YN, OMZ_YN, OMZ_YN, YN_IN_SCROLLBACK]);
    const ok = await spawnWorkerInPane('', '%1', CONFIG, { ...pane, ...FAST });
    assert.equal(ok, true);
    assert.equal(pane.sent.length, 2);
});

test('spawnWorkerInPane does not type into an unanswered prompt', async () => {
    const pane = fakePane([OMZ_YN]);
    const ok = await spawnWorkerInPane('', '%1', CONFIG, { ...pane, ...FAST });
    assert.equal(ok, false);
    assert.equal(pane.sent.length, 0);
});
