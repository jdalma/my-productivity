/**
 * The team's event log, events.jsonl: one JSON object per line, appended, never rewritten. It is the team's
 * timeline across workers; mailbox and archive files hold each worker's own state.
 *
 * The line format lives here, in EVENT_TYPES (T60; docs/events-format.md shows it with examples). Every line
 * written now has `ts`, `type`, `team` and `worker` (who acted: a message's sender, a refused worker) and
 * only the keys its type lists; a key not listed, or a missing required one, is an error, so a test catches
 * it. Free text other than a message body is cut at TEXT_LIMIT. Lines written before this format (no type,
 * no team, session keys) read back through readEvent in the same shape as new ones.
 *
 * A failure to write is swallowed (stderr warning): the mail itself must not wait on the log.
 */

import { appendFile, mkdir } from 'fs/promises';
import { dirname, join } from 'path';

export function eventsLogPath(stateRoot) {
    return join(stateRoot, 'events.jsonl');
}

const COMMON = ['ts', 'type', 'team', 'worker'];

/** Per type: keys every line has, keys it may have, and keys still read from older lines (never written). */
export const EVENT_TYPES = {
    message: {
        required: ['from', 'to', 'body', 'message_id', 'reply_to', 'expects_reply'],
        optional: ['from_team', 'to_team'],
        legacy: ['from_session', 'to_session'],
    },
    'tmux-denied': { required: ['args'], optional: [], legacy: [] },   // the tmux shim (T56)
    'tool-denied': { required: ['tool', 'rule', 'target'], optional: [], legacy: [] },   // the worker guard hook (T59)
};

/**
 * Free text a refusal records (a command, a path, tmux arguments) is cut here: enough to see what was
 * tried, not the whole of a pasted secret or a 100 KB send-keys body. A message body is the message and
 * is not cut.
 */
export const TEXT_LIMIT = 500;
const ARGS_LIMIT = 20;

function cut(s) {
    const text = String(s);
    return text.length > TEXT_LIMIT ? `${text.slice(0, TEXT_LIMIT)}…[+${text.length - TEXT_LIMIT} chars]` : text;
}

function cutArgs(args) {
    const kept = args.slice(0, ARGS_LIMIT).map(cut);
    return args.length > ARGS_LIMIT ? [...kept, `…[+${args.length - ARGS_LIMIT} args]`] : kept;
}

/** A line of `fields.type` as it is written: checked against EVENT_TYPES, stamped, free text cut. */
export function eventLine(fields) {
    const spec = EVENT_TYPES[fields.type];
    if (!spec) throw new Error(`events: unknown type '${fields.type}'`);
    const allowed = new Set([...COMMON, ...spec.required, ...spec.optional]);
    const unknown = Object.keys(fields).filter((k) => !allowed.has(k));
    if (unknown.length) throw new Error(`events: '${fields.type}' has no key ${unknown.join(', ')}`);
    const missing = [...COMMON.filter((k) => k !== 'ts'), ...spec.required].filter((k) => !(k in fields));
    if (missing.length) throw new Error(`events: '${fields.type}' needs ${missing.join(', ')}`);
    const line = { ts: fields.ts ?? new Date().toISOString(), ...fields };
    if (line.type === 'tmux-denied') line.args = cutArgs(line.args);
    if (line.type === 'tool-denied') line.target = cut(line.target);
    return line;
}

async function write(stateRoot, line) {
    const path = eventsLogPath(stateRoot);
    try {
        await mkdir(dirname(path), { recursive: true });
        await appendFile(path, JSON.stringify(line) + '\n', 'utf-8');
    } catch (err) {
        process.stderr.write(`[my-team] events.jsonl append failed: ${err.message}\n`);
    }
}

/** One line of any type in EVENT_TYPES. Throws when the fields do not fit it. */
export async function appendEvent(stateRoot, fields) {
    await write(stateRoot, eventLine(fields));
}

/** A message line: `team` is the sender's team, its `worker` the sender (also `from`, kept for older readers). */
export async function appendMessageEvent(stateRoot, { team, from, to, body, message_id, reply_to, expects_reply, ...optional }) {
    await appendEvent(stateRoot, {
        type: 'message', team, worker: from, from, to, body,
        message_id: message_id ?? null, reply_to: reply_to ?? null, expects_reply: Boolean(expects_reply), ...optional,
    });
}

/**
 * Any line as the current format has it. `team` is the team whose log it was read from: lines written
 * before T60 carry none (a mirrored message carries its sender's as from_team). A line without type is a v1
 * message; missing message keys read as null/false; keys of older formats stay as they are.
 */
export function readEvent(raw, team) {
    const type = raw.type ?? 'message';
    const line = { ...raw, type, team: raw.team ?? raw.from_team ?? team ?? null };
    if (type === 'message') {
        line.worker = raw.worker ?? raw.from ?? null;
        line.message_id = raw.message_id ?? null;
        line.reply_to = raw.reply_to ?? null;
        line.expects_reply = Boolean(raw.expects_reply);
    } else {
        line.worker = raw.worker ?? null;
    }
    return line;
}
