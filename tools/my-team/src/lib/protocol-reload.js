/**
 * A worker's AGENTS.md put back into its context after a context compaction (claude workers only).
 *
 * The worker reads AGENTS.md during its conversation; it is not part of the system prompt. A compaction keeps
 * only what its summary kept, so the protocol can be lost in the middle of a session. Claude Code runs
 * SessionStart hooks with matcher `compact` right after a compaction and adds their stdout to the context.
 * Past 10,000 characters it puts one hook's output in a file and shows the model only the first 2,000 and the
 * file's path, so the file goes out in parts, one hook command each. The
 * commands run side by side and their outputs arrive in any order, so each part says which one it is.
 */

import { fileURLToPath } from 'url';

import { shellQuote } from './worker-guard.js';

const HOOK = fileURLToPath(new URL('../worker-protocol-hook.js', import.meta.url));

// below Claude Code's 10,000 character cut, with room for the line partText puts first
const PART_LIMIT = 9000;

/**
 * The text in parts of whole lines, each at most PART_LIMIT characters (Claude Code counts characters, not
 * bytes). A line longer than the limit (an extra_prompt written as one line) is cut into pieces of that length,
 * so the parts put back together have line breaks inside it that the file does not.
 */
export function splitProtocol(text) {
    if (!text) return [];
    const lines = text.split('\n').flatMap((line) => {
        const pieces = [];
        for (let at = 0; at < line.length;) {
            let end = Math.min(at + PART_LIMIT, line.length);
            // not between the two halves of one character
            if (end < line.length && line.charCodeAt(end - 1) >= 0xd800 && line.charCodeAt(end - 1) <= 0xdbff) end -= 1;
            pieces.push(line.slice(at, end));
            at = end;
        }
        return pieces.length ? pieces : [''];
    });
    const parts = [];
    let part = [], size = 0;
    for (const line of lines) {
        if (part.length && size + line.length + 1 > PART_LIMIT) {
            parts.push(part.join('\n'));
            part = [];
            size = 0;
        }
        part.push(line);
        size += line.length + 1;
    }
    parts.push(part.join('\n'));
    return parts;
}

/** What hook number `part` (from 1) prints: that part under one line saying what it is; '' past the last. */
export function partText(path, text, part) {
    const parts = splitProtocol(text);
    if (!(part >= 1 && part <= parts.length)) return '';
    return `my-team worker protocol, part ${part} of ${parts.length}, from ${path}. This conversation was compacted; this is the protocol this worker read when it started, and it still applies. The parts may be in a different order here than in the file.\n\n${parts[part - 1]}\n`;
}

/** The SessionStart entry for a worker's settings file: one command per part of its AGENTS.md as it is now. */
export function protocolReloadHook(overlayPath, text) {
    return {
        matcher: 'compact',
        hooks: splitProtocol(text).map((_, i) => ({
            type: 'command',
            command: ['node', shellQuote(HOOK), '--file', shellQuote(overlayPath), '--part', String(i + 1)].join(' '),
        })),
    };
}
