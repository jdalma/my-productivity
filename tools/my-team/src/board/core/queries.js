/**
 * The board's read side (T63d, rfc/board-design.md §6.1): what a reviewer, a worker and the app ask of it.
 * Plain reads over the store contract; nothing here writes, so nothing waits on a writer (R67 R2).
 */

import { BoardError, TERMINAL, pmsOf } from './rules.js';

const RECENT = 20;
const byPriority = (a, b) => a.priority - b.priority || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const judgesOf = (task, roster) => (task.reviewer ? [task.reviewer] : pmsOf(roster));

async function approvedLandings(store) {
    return new Set((await store.list('verdict', { verdict: 'approve' })).map((v) => v.landing_id));
}

async function familyOf(store, task) {
    const rootId = task.parent_id ?? task.id;
    const root = rootId === task.id ? task : await store.get('task', rootId);
    return [root, ...(await store.list('task', { parent_id: rootId }))];
}

/** Open: `open`, or `fixed` in a landing no approve has covered yet (§3.2). */
const isOpen = (f, approved) => f.state === 'open' || (f.state === 'fixed' && !approved.has(f.fixed_in));

/** R64 §1: what a review request row must answer from the board alone. */
const REQUIRED_TASK_FIELDS = ['ticket_path', 'constraints'];

/**
 * The review requests `reviewer` judges: the open landing of each task in review, by priority. A row whose
 * task lacks a ticket or constraints is not workable (R64 §3) and is listed under `incomplete` instead.
 */
export async function reviewQueue(store, roster, reviewer) {
    const approved = await approvedLandings(store);
    const tasks = (await store.list('task', { state: 'review' })).filter((t) => judgesOf(t, roster).includes(reviewer)).sort(byPriority);
    const queue = [], incomplete = [];
    for (const task of tasks) {
        const [landing] = await store.list('landing', { task_id: task.id, superseded_by: null });
        if (!landing) continue;
        const missing = REQUIRED_TASK_FIELDS.filter((f) => task[f] === null);
        if (missing.length) { incomplete.push({ landing: landing.id, task: task.id, missing }); continue; }
        const family = await familyOf(store, task);
        const findings = await store.list('finding', { task_id: family.map((t) => t.id) });
        queue.push({
            task,
            parent: task.parent_id ? family[0] : null,
            landing,
            open_findings: findings.filter((f) => isOpen(f, approved)),
            settled_findings: findings.filter((f) => !isOpen(f, approved) && f.state !== 'fixed'),
        });
    }
    return { queue, incomplete };
}

/**
 * A worker's own: its unfinished tasks not waiting on someone else (ready, doing, changes, held), its review
 * requests, and notes to it and announcements after `since` ({note, announcement} seqs). `cursor` is the
 * `since` for the next call; nothing is marked read on the board.
 */
export async function inbox(store, roster, worker, since = {}) {
    const after = (rows, seq) => rows.filter((r) => r.seq > (seq ?? 0));
    const tasks = (await store.list('task', { assignee: worker, state: ['ready', 'doing', 'changes', 'held'] })).sort(byPriority);
    const { queue, incomplete } = await reviewQueue(store, roster, worker);
    const notes = await store.list('note', {});
    const announcements = await store.list('announcement', {});
    const last = (rows, seq) => rows.reduce((m, r) => Math.max(m, r.seq), seq ?? 0);
    return {
        tasks,
        review_queue: queue,
        incomplete,
        notes: after(notes, since.note).filter((n) => n.to?.includes(worker)),
        announcements: after(announcements, since.announcement),
        cursor: { note: last(notes, since.note), announcement: last(announcements, since.announcement) },
    };
}

/**
 * The whole board (the app's view, D1·D2), or with `task` that task's family in full. `workers` counts work
 * only; whether a worker is alive is status.json's and tmux's to say (§6.1).
 */
export async function status(store, roster, { task } = {}) {
    const approved = await approvedLandings(store);
    if (task) {
        const row = (await store.get('task', task)) ?? (() => { throw new BoardError('not-found', `no task ${task}`); })();
        const tasks = await familyOf(store, row);
        const ids = tasks.map((t) => t.id);
        const landings = await store.list('landing', { task_id: ids });
        return {
            root: tasks[0],
            tasks,
            landings,
            verdicts: await store.list('verdict', { landing_id: landings.map((l) => l.id) }),
            findings: await store.list('finding', { task_id: ids }),
        };
    }
    const tasks = (await store.list('task', {})).sort(byPriority);
    const live = tasks.filter((t) => !TERMINAL.includes(t.state));
    const findings = await store.list('finding', { state: ['open', 'fixed'] });
    const log = await store.logSince(0, Number.MAX_SAFE_INTEGER);
    return {
        store: await store.describe(),
        tasks,
        workers: roster.map((w) => ({
            name: w.name,
            role: w.role ?? null,
            assigned: live.filter((t) => t.assignee === w.name).length,
            reviewing: live.filter((t) => judgesOf(t, roster).includes(w.name)).length,
        })),
        open_findings: findings.filter((f) => isOpen(f, approved)),
        recent: log.slice(-RECENT),
    };
}
