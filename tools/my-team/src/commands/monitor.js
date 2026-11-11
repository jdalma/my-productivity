/**
 * `my-team monitor <team-name>` — tail -f the worker-to-worker message event log.
 *
 * Minimal interface by design: takes only a team name, always follows in real-time,
 * always shows every message. No filtering, no limit, no formatting options.
 *
 * Output format (per message, multi-line):
 *   [HH:MM:SS] <from> → <to>
 *      <body original line 1>
 *      <body original line 2>
 *
 *   [HH:MM:SS] <next-from> → <next-to>
 *      ...
 *
 * Ctrl+C to exit.
 */

import { existsSync, openSync, readSync, closeSync, watch, statSync } from 'fs';
import { loadManifest } from './_manifest.js';
import { eventsLogPath, readEvent } from '../lib/events.js';

function formatTimestamp(isoTs) {
    // "2026-05-13T15:42:31.123Z" -> "15:42:31"
    try {
        return new Date(isoTs).toTimeString().slice(0, 8);
    } catch {
        return isoTs;
    }
}

function formatBody(body) {
    return body
        .split('\n')
        .map((line) => `   ${line}`)
        .join('\n');
}

function renderEvent(raw, team) {
    const entry = readEvent(raw, team);
    const ts = formatTimestamp(entry.ts);
    if (entry.type === 'tmux-denied') return `[${ts}] ${entry.worker}: tmux ${(entry.args ?? []).join(' ')} 거부됨\n\n`;
    if (entry.type === 'tool-denied') return `[${ts}] ${entry.worker}: ${entry.tool} ${entry.target} 거부됨 (${entry.rule})\n\n`;
    if (entry.type !== 'message') return `[${ts}] ${entry.type} (${entry.worker ?? '?'})\n\n`;
    const header = `[${ts}] ${entry.from} → ${entry.to}`;
    const body = formatBody(entry.body ?? '');
    // Trailing blank line separates this event from the next.
    return `${header}\n${body}\n\n`;
}

function processNewBytes(buffer, team) {
    // Buffer may contain partial last line — return rendered output + remainder.
    const lines = buffer.split('\n');
    const remainder = lines.pop(); // either '' (clean newline) or partial line
    const rendered = [];
    for (const line of lines) {
        if (!line.trim()) continue;
        try {
            const entry = JSON.parse(line);
            rendered.push(renderEvent(entry, team));
        } catch {
            // Skip malformed lines silently — events.jsonl should always be valid.
        }
    }
    return { output: rendered.join(''), remainder };
}

export async function runMonitor(teamName, opts = {}) {
    if (!teamName) {
        throw new Error('team name is required: my-team monitor <team-name>');
    }

    const manifest = loadManifest(teamName, opts.stateRoot);
    const path = eventsLogPath(manifest.state_root);

    console.log(`[my-team monitor] team='${teamName}' log=${path}`);
    console.log('[my-team monitor] Ctrl+C to exit.\n');

    // Read everything that already exists, then watch for new appends.
    let position = 0;
    let pending = '';

    function readFromPosition() {
        if (!existsSync(path)) return;
        let size;
        try {
            size = statSync(path).size;
        } catch {
            return;
        }
        if (size <= position) return;
        const fd = openSync(path, 'r');
        try {
            const chunkSize = size - position;
            const buf = Buffer.alloc(chunkSize);
            readSync(fd, buf, 0, chunkSize, position);
            position = size;
            const text = pending + buf.toString('utf-8');
            const { output, remainder } = processNewBytes(text, manifest.team_name);
            pending = remainder;
            if (output) process.stdout.write(output);
        } finally {
            closeSync(fd);
        }
    }

    // Initial drain — show history first.
    readFromPosition();

    // Watch for changes. fs.watch fires on append; on macOS/Linux this is reliable.
    if (!existsSync(path)) {
        // File doesn't exist yet; touch by watching the parent dir until it appears.
        const dirPath = path.replace(/\/[^/]+$/, '');
        watch(dirPath, () => {
            if (existsSync(path)) {
                readFromPosition();
            }
        });
    } else {
        watch(path, () => {
            readFromPosition();
        });
    }

    // Block forever — fs.watch keeps the event loop alive.
    return new Promise(() => {});
}
