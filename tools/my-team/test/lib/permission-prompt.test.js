/**
 * Unit tests for paneHasPermissionPrompt — the guard that stops sendToWorker
 * from typing into (and accidentally answering) a worker's tool-permission
 * modal.
 *
 * The PASSING fixtures are real `tmux capture-pane` output captured live from
 * Claude Code v2.1.x permission modals (Read "Do you want to proceed?" and
 * Write "Do you want to overwrite …?"). The FAILING fixtures are ordinary
 * pane states that must NOT be mistaken for a modal — including a normal input
 * line that merely starts with ❯, which is the exact ambiguity that made the
 * original sendToWorker lose startup messages.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { paneHasPermissionPrompt } from '../../src/lib/tmux-session.js';

// ── Real modals (must be detected) ──────────────────────────────────────────

const READ_MODAL = `
⏺ 팀이 라이브 상태입니다. /tmp/AGENTS.md의 피어 프로토콜을 먼저 확인하겠습니다.

  Reading 1 file… (ctrl+o to expand)
  ⎿  /tmp/AGENTS.md

 Read file

  Read(/tmp/AGENTS.md)

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, allow reading from tmp/ during this session
   3. No

 Esc to cancel · Tab to amend
`;

const WRITE_MODAL = `
⏺ Write(sample.txt)

  1 -test content
  1 +edited

 Do you want to overwrite sample.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
`;

// ── Non-modals (must NOT be detected) ───────────────────────────────────────

// A normal, idle input line that happens to start with ❯ — this is the case
// the original code conflated with "ready". No numbered Yes/No menu present.
const IDLE_INPUT = `
  지시를 입력해 주시거나, 팀 동료가 메일박스로 작업을 위임하면 처리하겠습니다.

────────────────────────────────────────────────────────────────────────────
❯ Spring Boot 회원가입·로그인 인증 방식 베스트 프랙티스 조사해줘
────────────────────────────────────────────────────────────────────────────
  [OMC#4.13.7]
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
`;

// Transcript text that mentions "Do you want to" but has no menu/footer.
const PROSE_MENTION = `
⏺ 제가 물어볼게요: Do you want to proceed with option A or B?
  1. 카테고리 도메인 개발
  2. 회원가입/로그인
  번호로 답해 주세요.
❯
`;

const EMPTY = '';

test('detects a live Read permission modal', () => {
    assert.equal(paneHasPermissionPrompt(READ_MODAL), true);
});

test('detects a live Write/overwrite permission modal', () => {
    assert.equal(paneHasPermissionPrompt(WRITE_MODAL), true);
});

test('does not flag a normal idle input line starting with ❯', () => {
    assert.equal(paneHasPermissionPrompt(IDLE_INPUT), false);
});

test('does not flag transcript prose that merely says "Do you want to"', () => {
    // No "N. Yes" + "N. No" numbered menu, so it must not match.
    assert.equal(paneHasPermissionPrompt(PROSE_MENTION), false);
});

test('does not flag empty pane content', () => {
    assert.equal(paneHasPermissionPrompt(EMPTY), false);
});
