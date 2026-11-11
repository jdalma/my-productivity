/**
 * The notice `my-team start` types into each worker's pane (T66). Each notice costs the worker a turn, so a
 * worker that already knows its instructions is not told them again:
 *   - a new team, a worker with no AGENTS.md before, or one that does not carry its conversation over: the
 *     full notice, as always;
 *   - `--continue` and a resumed conversation with the same AGENTS.md: nothing, or one line about mail waiting;
 *   - `--continue` and a resumed conversation with a changed AGENTS.md: one line naming the changed sections.
 */

import { sendToWorker } from './tmux-session.js';

/** sendToWorker refuses a longer message, and the worker then gets nothing (R2 L2). */
const SEND_LIMIT = 500;

export function fullNotice(overlayPath) {
    return `Team is live. Follow ${overlayPath} for the peer protocol; wait for user input in this pane or peer messages in your mailbox.`;
}

/**
 * Whether the worker starts inside its previous conversation, so it already holds its instructions: claude
 * with --resume or --continue (what the session-resume skill adds). Any other agent cannot be told apart here
 * and counts as not, so it gets the full notice (the safe side).
 */
export function continuesConversation(agentType, launchArgs = []) {
    if (agentType !== 'claude') return false;
    return launchArgs.some((a) => a === '--resume' || a === '-r' || a.startsWith('--resume=') || a === '--continue' || a === '-c');
}

/** The text of each "## " section ("### " stays inside its section); what comes before the first is "(top)". */
function sections(text) {
    const out = new Map();
    let title = '(top)';
    let body = [];
    for (const line of text.split('\n')) {
        if (line.startsWith('## ')) {
            out.set(title, body.join('\n'));
            title = line.slice(3).trim();
            body = [];
        } else {
            body.push(line);
        }
    }
    out.set(title, body.join('\n'));
    return out;
}

/** The "## " section titles added, changed and removed between two AGENTS.md texts, in document order. */
export function sectionChanges(before, after) {
    const a = sections(before), b = sections(after);
    return {
        added: [...b.keys()].filter((t) => !a.has(t)),
        changed: [...b.keys()].filter((t) => a.has(t) && a.get(t) !== b.get(t)),
        removed: [...a.keys()].filter((t) => !b.has(t)),
    };
}

/**
 * The notice for one worker, or null for none. previous is its AGENTS.md before this start wrote the new one
 * (null when there was none); mail is {spool, unread} from its mailbox.
 */
export function startupNotice({ overlayPath, keep, previous, current, agentType, launchArgs, mail }) {
    if (!keep || previous === null || !continuesConversation(agentType, launchArgs)) return fullNotice(overlayPath);
    const waiting = (mail?.spool ?? 0) + (mail?.unread ?? 0);
    const mailLine = waiting ? ` You have ${waiting} waiting message(s): run your mailbox-list.` : '';
    if (previous === current) return mailLine ? `Team is live again; your AGENTS.md is unchanged.${mailLine}` : null;
    const { added, changed, removed } = sectionChanges(previous, current);
    const titles = [...added.map((t) => ['added', t]), ...changed.map((t) => ['changed', t]), ...removed.map((t) => ['removed', t])];
    // as many titles as fit in one sendable line, the rest counted; none fit: the full notice
    for (let shown = titles.length; shown >= 1; shown--) {
        const parts = ['added', 'changed', 'removed']
            .map((what) => [what, titles.slice(0, shown).filter(([w]) => w === what).map(([, t]) => t)])
            .filter(([, ts]) => ts.length).map(([what, ts]) => `${what}: ${ts.join(', ')}`);
        const more = titles.length - shown ? `; and ${titles.length - shown} more` : '';
        const line = `Team is live again. Your instructions in ${overlayPath} changed (${parts.join('; ')}${more}): read those sections.${mailLine}`;
        if (line.length <= SEND_LIMIT) return line;
    }
    return fullNotice(overlayPath);
}

/** Types each worker's notice into its pane, skipping those with none; returns the names not delivered. */
export async function sendStartupNotices(sessionName, workers, send = sendToWorker) {
    const undelivered = [];
    for (const w of workers) {
        if (w.notice === null) continue;
        if (await send(sessionName, w.pane_id, w.notice) === false) undelivered.push(w.name);
    }
    return undelivered;
}
