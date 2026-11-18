/**
 * Unit tests for messageStillInInputLine — the submit-detection used by
 * sendToWorker to decide whether a message is still unsent in the worker's
 * input line vs. already submitted (and merely echoed into the transcript).
 *
 * The old check (whole-screen substring) reported a delivered message as
 * "still there" because the worker CLI echoes the submitted line into
 * scrollback. These fixtures are real `tmux capture-pane` shapes from Claude
 * Code v2.1.x covering both states.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { messageStillInInputLine } from '../../src/lib/tmux-session.js';

const MSG = 'E2E_PROBE_MESSAGE_조사해줘';

// Message still typed into the input line, NOT yet submitted.
const UNSENT = `
  지시를 입력해 주시거나, 팀 동료가 메일박스로 작업을 위임하면 처리하겠습니다.

────────────────────────────────────────────────────────────────────────────
❯ ${MSG}
────────────────────────────────────────────────────────────────────────────
  [OMC#4.13.7]
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
`;

// Message submitted: it now appears as a transcript echo (❯ scrollback + the
// agent quoting it) while the LIVE input line at the bottom is empty.
const SENT_ECHO = `
❯ target.txt 파일 내용을 CHANGED 로 덮어써줘. 설명 없이 바로.
❯ ${MSG}
⏺ ${MSG}라는 문자열을 조사하라는 요청으로 이해했습니다. 코드베이스에서 찾아보겠습니다.

────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────
  [OMC#4.13.7]
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
`;

// A long message wrapped across two rows in the input line (still unsent).
const UNSENT_WRAPPED = `
────────────────────────────────────────────────────────────────────────────
❯ Team is live. Follow /tmp/AGENTS.md for the peer protocol; wait for user
  input in this pane or peer messages in your mailbox.
────────────────────────────────────────────────────────────────────────────
  [OMC#4.13.7]
`;

test('detects a message still unsent in the input line', () => {
    assert.equal(messageStillInInputLine(UNSENT, MSG), true);
});

test('does not count a submitted message echoed into the transcript', () => {
    // The live input line is empty; the message only survives as scrollback.
    assert.equal(messageStillInInputLine(SENT_ECHO, MSG), false);
});

test('detects an unsent message wrapped across input-line rows', () => {
    const wrapped = 'wait for user input in this pane or peer messages in your mailbox';
    assert.equal(messageStillInInputLine(UNSENT_WRAPPED, wrapped), true);
});
