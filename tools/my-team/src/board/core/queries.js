/**
 * The board's read side (T63d; docs/board.md, Commands): what a reviewer, a worker and the app ask of it.
 * Plain reads over the store contract; nothing here writes, so nothing waits on a writer (R67 R2).
 */

import { BoardError, IN_HAND, TERMINAL, nextVerdictId, pmsOf } from './rules.js';

const RECENT = 20;
const ANNOUNCEMENTS = 10;
/** In how many landings a failure is named before the board calls it repeated (T53). */
const REPEATED = 3;
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

/**
 * The backlog findings a landing names in `closes` (T198): its approve fixes them, and until then they stay backlog.
 * This landing's only: a finding an earlier landing of the task named may have been reopened and settled since.
 */
export async function pendingBacklogCloses(store, landing) {
    const found = await Promise.all([...new Set(landing.closes)].map((id) => store.get('finding', id)));
    return found.filter((f) => f?.state === 'backlog');
}

/** Open: `open`, or `fixed` in a landing no approve has covered yet. */
const isOpen = (f, approved) => f.state === 'open' || (f.state === 'fixed' && !approved.has(f.fixed_in));

/** A progress log entry as `board-status` with `task` lists it (T127). */
const progressOf = (e) => ({ item: e.detail.item, note: e.detail.note, done: e.detail.done, by: e.actor, at: e.at });

/**
 * Each task's progress at a glance (T127): the items whose latest report says done, and the latest note. Item 0 is
 * work outside the ticket's items, never an item done.
 */
function progressSummaries(log) {
    const out = new Map();
    for (const e of log) {
        if (e.action !== 'progress') continue;
        const s = out.get(e.ref) ?? { items: new Map() };
        if (e.detail.item > 0) s.items.set(e.detail.item, e.detail.done);
        s.last_note = e.detail.note;
        s.last_at = e.at;
        out.set(e.ref, s);
    }
    return new Map([...out].map(([ref, s]) => [ref, {
        done_items: [...s.items].filter(([, done]) => done).map(([item]) => item).sort((a, b) => a - b),
        last_note: s.last_note, last_at: s.last_at,
    }]));
}

/**
 * Each task's history from the log (T156): how many landings and verdicts it had, its last event, since when
 * it is in its state, who reported progress last, and the state a cancelled one was in. A landing's log entry
 * names its task, and a verdict's its landing. A progress report and an edit are no events; a landing again in
 * review enters no state.
 */
function histories(log) {
    const out = new Map(), taskOfLanding = new Map();
    const of = (id) => out.get(id) ?? out.set(id, {
        landings: 0, verdicts: { approve: 0, changes: 0, hold: 0 }, last_event: null, state_since: null,
        last_progress_by: null, cancelled_from: null, waited_in: null,
    }).get(id);
    for (const e of log) {
        if (e.kind === 'landing') taskOfLanding.set(e.ref, e.detail.task);
        const id = e.kind === 'task' ? e.ref : e.kind === 'landing' ? e.detail.task : e.kind === 'verdict' ? taskOfLanding.get(e.detail.landing) : null;
        if (!id) continue;
        const h = of(id);
        if (e.action === 'progress') { h.last_progress_by = e.actor; continue; }
        if (e.action === 'edit') continue;
        if (e.action === 'land') h.landings++;
        if (e.action === 'verdict') h.verdicts[e.detail.verdict]++;
        if (e.action === 'wait') h.waited_in = e.state_from;
        if (e.action === 'cancel') h.cancelled_from = e.state_from === 'waiting' ? h.waited_in : e.state_from;
        const from = e.state_from ?? null, to = e.state_to ?? null;
        if (to && to !== from) h.state_since = e.at;
        h.last_event = { action: e.action, verdict: e.action === 'verdict' ? e.detail.verdict : null, by: e.actor, at: e.at, state_from: from, state_to: to };
    }
    return out;
}

const NO_HISTORY = { landings: 0, verdicts: { approve: 0, changes: 0, hold: 0 }, last_event: null, last_progress_by: null, cancelled_from: null };

function withSummary(t, summaries, hist) {
    const { waited_in: _, ...h } = hist.get(t.id) ?? NO_HISTORY;
    return { ...t, progress_summary: summaries.get(t.id) ?? null, history: { ...h, state_since: h.state_since ?? t.created_at } };
}

const EMPTY_BRIEF = { context: null, options: [], recommendation: null, impact: null, refs: [] };
const NOT_EDITED = { edits: 0, edited_by: null, edited_at: null };

/** One entry of the decision list (T146): the brief's fields at the top, the answer's when there is one. */
function decisionEntry({ id, task_id, tasks, brief, question, asked_by, asked_at, answer, seq, edited }) {
    const { question: _, ...rest } = { ...EMPTY_BRIEF, ...(brief ?? {}) };
    return {
        id, task_id, tasks, state: answer ? 'answered' : 'open', question: brief?.question ?? question,
        context: rest.context, options: rest.options, recommendation: rest.recommendation, impact: rest.impact, refs: rest.refs,
        asked_by, asked_at,
        ...(edited ?? NOT_EDITED),
        ...(answer ? { chosen: answer.chosen, answer: answer.answer, answered_by: answer.answered_by, answered_at: answer.answered_at } : {}),
        // the log seq of the answer, for board-inbox's cursor; not part of the list
        seq: seq ?? null,
    };
}

/** The id of a task's nth wait in the decision list: the same on every call (T146). */
export const waitId = (taskId, n) => `${taskId}:${n}`;

/**
 * Every decision asked of the user, oldest first (T146): a task's waits from the log, numbered per task (`T5:1` is
 * T5's first wait, the same id on every call), and the decisions of board-ask. A wait whose task was cancelled
 * before an answer counts as withdrawn.
 */
export function decisionsOf(log, tasks, rows) {
    const byId = new Map(tasks.map((t) => [t.id, t]));
    const asked = new Map(), open = new Map(), out = [];
    const answerSeq = new Map(log.filter((e) => e.kind === 'decision' && e.action === 'answer').map((e) => [e.ref, e.seq]));
    const edited = new Map();
    for (const e of log) {
        if (e.kind === 'decision' && e.action === 'edit') {
            edited.set(e.ref, { edits: (edited.get(e.ref)?.edits ?? 0) + 1, edited_by: e.actor, edited_at: e.at });
        }
        if (e.kind !== 'task') continue;
        if (e.action === 'wait') {
            const n = (asked.get(e.ref) ?? 0) + 1;
            asked.set(e.ref, n);
            open.set(e.ref, { id: waitId(e.ref, n), task_id: e.ref, tasks: [e.ref], question: e.detail?.question ?? null, asked_by: e.actor, asked_at: e.at });
        } else if ((e.action === 'answer' || e.action === 'cancel') && open.has(e.ref)) {
            const q = open.get(e.ref);
            open.delete(e.ref);
            const d = e.detail ?? {};
            const answer = e.action === 'answer'
                ? { chosen: d.chosen, answer: d.answer, answered_by: d.answered_by ?? e.actor, answered_at: d.answered_at ?? e.at }
                : { chosen: '철회', answer: d.reason ? `작업이 취소되었습니다: ${d.reason}` : '작업이 취소되었습니다', answered_by: e.actor, answered_at: e.at };
            out.push(decisionEntry({ ...q, brief: d.brief ?? null, answer, seq: e.seq, edited: edited.get(q.id) }));
        }
    }
    for (const q of open.values()) {
        const { asked_by: _a, asked_at: _t, resume_state: _r, ...brief } = byId.get(q.task_id)?.waiting ?? {};
        out.push(decisionEntry({ ...q, brief: brief.question ? brief : null, edited: edited.get(q.id) }));
    }
    for (const r of rows) {
        out.push(decisionEntry({
            id: r.id, task_id: null, tasks: r.tasks, brief: r.brief, asked_by: r.created_by, asked_at: r.created_at, answer: r.answer,
            seq: answerSeq.get(r.id), edited: edited.get(r.id),
        }));
    }
    return out.sort((a, b) => (a.asked_at < b.asked_at ? -1 : a.asked_at > b.asked_at ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

const listed = ({ seq: _, ...d }) => d;

/** R64 §1: what a review request row must answer from the board alone. */
const REQUIRED_TASK_FIELDS = ['ticket_path', 'constraints'];

/**
 * The review requests `reviewer` judges: the open landing of each task in review, by priority. A row whose
 * task lacks a ticket or constraints is not workable (R64 §3) and is listed under `incomplete` instead.
 */
export async function reviewQueue(store, roster, reviewer) {
    const approved = await approvedLandings(store);
    const allVerdicts = await store.list('verdict', {});
    const tasks = (await store.list('task', { state: 'review' })).filter((t) => judgesOf(t, roster).includes(reviewer)).sort(byPriority);
    const queue = [], incomplete = [];
    for (const task of tasks) {
        const own = await store.list('landing', { task_id: task.id });
        const landing = own.find((l) => l.superseded_by === null);
        if (!landing) continue;
        // blank counts as missing: "없음" is how a task says it has no constraints (R71 R2)
        const missing = REQUIRED_TASK_FIELDS.filter((f) => !task[f]?.trim());
        if (missing.length) { incomplete.push({ landing: landing.id, task: task.id, missing }); continue; }
        const family = await familyOf(store, task);
        const ids = family.map((t) => t.id);
        const findings = await store.list('finding', { task_id: ids });
        const familyLandings = new Set((await store.list('landing', { task_id: ids })).map((l) => l.id));
        const verdicts = allVerdicts.filter((v) => familyLandings.has(v.landing_id));
        queue.push({
            task,
            parent: task.parent_id ? family[0] : null,
            landing,
            // what the reviewer last saw of this task: the commit of the landing this one superseded (R70 R2)
            // null too after a document task's landing, which has none
            previous_commit: own.find((l) => l.superseded_by === landing.id)?.commit || null,
            open_findings: findings.filter((f) => isOpen(f, approved)),
            settled_findings: findings.filter((f) => !isOpen(f, approved) && f.state !== 'fixed'),
            // findings of other families this landing closed: the reviewer checks those fixes too (T87)
            closes_outside: [...await store.list('finding', { fixed_in: landing.id }), ...await pendingBacklogCloses(store, landing)]
                .filter((f) => !ids.includes(f.task_id)),
            notes: await store.list('note', { task_id: ids }),
            verdicts,
            next_verdict: nextVerdictId(allVerdicts.map((v) => v.id), verdicts.map((v) => v.id)),
        });
    }
    const hint = queue.length > 1
        ? `${queue.length} review requests wait: give each to its own sub-agent of your CLI and start them together instead of judging them in turn; the verdicts stay yours`
        : null;
    return { queue, incomplete, ...(hint ? { hint } : {}) };
}

/**
 * A worker's own: its unfinished tasks not waiting on its reviewer (ready, doing, changes, held, waiting), its review
 * requests, notes to it and announcements after `since` ({board, note, announcement, decision}), the open decisions (all of
 * them for pm, its own for a worker) and the answers to its questions after `since` (T146). `cursor` is the
 * `since` for the next call; a cursor of another board (a new team's, R69 R2) starts from the beginning.
 * Nothing is marked read on the board.
 */
export async function inbox(store, roster, worker, cursor = {}) {
    const board = (await store.describe()).board_id;
    const since = cursor.board === board ? cursor : {};
    const after = (rows, seq) => rows.filter((r) => r.seq > (seq ?? 0));
    const tasks = (await store.list('task', { assignee: worker, state: ['ready', 'doing', 'changes', 'held', 'waiting'] })).sort(byPriority);
    const { queue, incomplete, hint } = await reviewQueue(store, roster, worker);
    const notes = await store.list('note', {});
    const announcements = await store.list('announcement', {});
    const last = (rows, seq) => rows.reduce((m, r) => Math.max(m, r.seq), seq ?? 0);
    const decisions = decisionsOf(await store.logSince(0, Number.MAX_SAFE_INTEGER), await store.list('task', {}), await store.list('decision', {}));
    // a cursor of this board from before T146 has no `decision`: the answers to waits it saw were told already (R3 L2)
    const legacy = since.board !== undefined && since.decision === undefined;
    const answered = decisions.filter((d) => d.state === 'answered' && d.asked_by === worker && d.seq > (since.decision ?? 0) && !(legacy && d.task_id));
    return {
        tasks,
        review_queue: queue,
        ...(hint ? { review_hint: hint } : {}),
        incomplete,
        notes: after(notes, since.note).filter((n) => n.to?.includes(worker)),
        announcements: after(announcements, since.announcement),
        // the decisions waiting for the user (pm's to record), and the answers to this worker's questions (T146)
        decisions: {
            open: decisions.filter((d) => d.state === 'open' && (pmsOf(roster).includes(worker) || d.asked_by === worker)).map(listed),
            answered: answered.map(listed),
        },
        cursor: {
            board, note: last(notes, since.note), announcement: last(announcements, since.announcement),
            decision: answered.reduce((m, d) => Math.max(m, d.seq), since.decision ?? 0),
        },
    };
}

/** Every commit an approve verdict covers in `repos`, one repository's top levels: the commits of its landings (T63f, T113). */
export async function approvedCommits(store, repos) {
    const approved = await approvedLandings(store);
    const landings = (await store.list('landing', { repo: repos })).filter((l) => approved.has(l.id));
    return new Set(landings.flatMap((l) => l.commits));
}

/**
 * The whole board (the app's view, D1·D2), or with `task` that task's family in full. `workers` counts work
 * only; whether a worker is alive is status.json's and tmux's to say.
 */
/**
 * The failures named in REPEATED landings or more, by a check or by a rerun of it, most often first (T53): a
 * flaky test or a standing excuse that wants a task of its own. An excused failure counts too.
 */
async function repeatedFailures(store) {
    const where = new Map();
    const named = (landing, names) => { for (const n of names ?? []) where.set(n, (where.get(n) ?? new Set()).add(landing)); };
    for (const l of await store.list('landing', {})) named(l.id, l.check_detail?.failures);
    for (const v of await store.list('verdict', {})) named(v.landing_id, v.rerun_detail?.failures);
    return [...where].filter(([, ls]) => ls.size >= REPEATED)
        .map(([name, ls]) => ({ name, count: ls.size, landings: [...ls].sort() }))
        .sort((a, b) => b.count - a.count || (a.name < b.name ? -1 : 1));
}

export async function status(store, roster, { task, open = false } = {}) {
    const approved = await approvedLandings(store);
    if (task) {
        const row = (await store.get('task', task)) ?? (() => { throw new BoardError('not-found', `no task ${task}`); })();
        const tasks = await familyOf(store, row);
        const ids = tasks.map((t) => t.id);
        const landings = await store.list('landing', { task_id: ids });
        const findings = await store.list('finding', { task_id: ids });
        // fixes of the family's findings made in other families' landings (T87): which, and whether approved,
        // since `verdicts` covers the family's own landings only
        const own = new Set(landings.map((l) => l.id));
        const elsewhere = [...new Set(findings.filter((f) => f.state === 'fixed' && f.fixed_in && !own.has(f.fixed_in)).map((f) => f.fixed_in))];
        const fixedElsewhere = [];
        for (const id of elsewhere.sort()) {
            fixedElsewhere.push({ landing: id, task_id: (await store.get('landing', id))?.task_id ?? null, approved: approved.has(id) });
        }
        const famLog = await store.logOf(ids);
        const summaries = progressSummaries(famLog);
        const verdicts = await store.list('verdict', { landing_id: landings.map((l) => l.id) });
        // the family's landings and verdicts are logged under their own ids
        const hist = histories(await store.logOf([...ids, ...landings.map((l) => l.id), ...verdicts.map((v) => v.id)]));
        // the user's decisions on the family (T115), oldest first: each answer with the question it answered
        const answers = famLog
            .filter((e) => e.action === 'answer')
            .map(({ ref, detail: d }) => ({
                task_id: ref, question: d.question, chosen: d.chosen, answer: d.answer, answered_by: d.answered_by,
                answered_at: d.answered_at, brief: d.brief ?? null,
            }));
        return {
            root: withSummary(tasks[0], summaries, hist),
            tasks: tasks.map((t) => withSummary(t, summaries, hist)),
            answers,
            // the asked task's own progress, oldest first (T127)
            progress: famLog.filter((e) => e.action === 'progress' && e.ref === row.id).map(progressOf),
            landings,
            verdicts,
            findings,
            fixed_elsewhere: fixedElsewhere,
            notes: await store.list('note', { task_id: ids }),
        };
    }
    const log = await store.logSince(0, Number.MAX_SAFE_INTEGER);
    const summaries = progressSummaries(log);
    const hist = histories(log);
    const tasks = (await store.list('task', {})).sort(byPriority).map((t) => withSummary(t, summaries, hist));
    const live = tasks.filter((t) => !TERMINAL.includes(t.state));
    const findings = await store.list('finding', { state: ['open', 'fixed'] });
    const repeated = await repeatedFailures(store);
    return {
        store: await store.describe(),
        // `open`: only what is not finished, so a worker in a new conversation reads the work at
        // hand and not the board's whole past
        tasks: open ? live : tasks,
        workers: roster.map((w) => ({
            name: w.name,
            role: w.role ?? null,
            assigned: live.filter((t) => t.assignee === w.name).length,
            in_hand: live.filter((t) => t.assignee === w.name && IN_HAND.includes(t.state)).length,
            reviewing: live.filter((t) => judgesOf(t, roster).includes(w.name)).length,
        })),
        open_findings: findings.filter((f) => isOpen(f, approved)),
        // what changed on the board: progress reports are no change, and are read per task (R47 S2)
        recent: log.filter((e) => e.action !== 'progress').slice(-RECENT),
        announcements: (await store.list('announcement', {})).slice(-ANNOUNCEMENTS),
        // every decision asked of the user, oldest first (T146)
        decisions: decisionsOf(log, tasks, await store.list('decision', {})).filter((d) => !open || d.state === 'open').map(listed),
        ...(repeated.length ? { repeated_failures: repeated } : {}),
    };
}
