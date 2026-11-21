/**
 * The board's write commands (T63c; docs/board.md, States). One function per command. Each
 * attempt reads, decides by the tables in rules.js, and applies one change set; a Conflict from the store
 * means someone changed what was read, so the attempt runs again from the read (3 attempts).
 *
 * The task row is the lock of its task: every write that affects a task, its landings, verdicts or
 * findings updates the task row at the version it read, even when the state stays. Writes that look at or
 * change findings lock the family's root task too, since findings span the family. A landing may close a
 * finding of another family (T87); a write that changes such a finding locks that finding's task and root.
 *
 * Ports (all injected):
 *   store     the store contract (contract.js)
 *   roster    () => [{name, role}]
 *   actor     the worker acting (resolved from MY_TEAM_WORKER by compose)
 *   now       () => ISO time
 *   git       { range(repo, base, commit) => {ancestor, commits} } — land's checks (T63e implements it)
 *   event     (fields) => Promise<boolean>, after the change is applied
 *   notify    (to[], ref, action) => Promise<string[] warnings>, after the event
 */

import {
    BoardError, COMMIT, DELIVERABLES, FINDING_CODE, FINDING_MOVES, FIXABLE, IN_HAND, SETTLED, SEVERITIES, TASK_ID, TERMINAL, VERDICTS,
    briefWarnings, fail, isDocument, loadWarning, move, nextDerived, nextNumbered, nextVerdictId, pmsOf,
} from './rules.js';
import { pendingBacklogCloses, waitId } from './queries.js';

const ATTEMPTS = 3;

const text = (v, name) => (typeof v === 'string' && v.trim() ? v : fail('invalid', `${name} is required`));
const texts = (v, name, { nonEmpty = false } = {}) => {
    if (!Array.isArray(v) || v.some((x) => typeof x !== 'string' || !x.trim())) fail('invalid', `${name} must be a list of strings`);
    if (nonEmpty && !v.length) fail('invalid', `${name} needs at least one item`);
    return v;
};

/** The states a task reports progress in: the assignee has it in hand (T127). */
const PROGRESS_STATES = ['doing', 'changes'];

/** "Other": the user chose none of the options (T115). */
const OTHER_CHOICE = '기타';
/** "Withdrawn": pm closes a decision nobody needs any more (T146). */
const WITHDRAWN = '철회';
/** A decision's id: D#, then its number in the team (T146, R3 M1). No task id has a #, so a task named D1 stays a task. */
const DECISION_ID = /^D#(\d+)$/;

/**
 * A decision brief someone can decide from alone (T115, T117): question, context, two options or more with their pros
 * and cons, a recommendation (an option, or none with the reason), impact; refs when given. Labels are kept
 * without the spaces around them, so `A` and `A ` are one label and ` 기타` is the reserved one.
 */
function brief(input, { least = 2 } = {}) {
    const options = input.options;
    if (!Array.isArray(options) || options.length < least) {
        fail('invalid', `options needs ${least === 1 ? 'one choice' : 'two choices'} or more, each {label, detail, pros, cons}`);
    }
    const labels = new Set();
    const choices = options.map((o, i) => {
        const label = text(o?.label, `options[${i}].label`).trim();
        if (labels.has(label) || label === OTHER_CHOICE || label === WITHDRAWN) {
            fail('invalid', `options[${i}].label '${label}' is ${labels.has(label) ? 'given twice' : 'kept for an answer outside the options'}`);
        }
        labels.add(label);
        return {
            label, detail: o.detail == null ? '' : text(o.detail, `options[${i}].detail`),
            pros: texts(o.pros, `options[${i}].pros`, { nonEmpty: true }), cons: texts(o.cons, `options[${i}].cons`, { nonEmpty: true }),
        };
    });
    const rec = input.recommendation;
    if (rec === null || typeof rec !== 'object' || Array.isArray(rec)) fail('invalid', 'recommendation is required: {option, reason}, or {option: null, reason} to recommend none');
    const recommended = rec.option == null ? null : typeof rec.option === 'string' ? rec.option.trim() : '';
    if (recommended !== null && !labels.has(recommended)) fail('invalid', `recommendation.option must be one of ${[...labels].join(', ')}, or null`);
    return {
        question: text(input.question, 'question'), context: text(input.context, 'context'), options: choices,
        recommendation: { option: recommended, reason: text(rec.reason, 'recommendation.reason') },
        impact: text(input.impact, 'impact'),
        refs: input.refs == null ? [] : texts(input.refs, 'refs'),
    };
}

/** The task row's `deliverable` from a command's input: `document`, or null for commits (T158). */
const deliverableOf = (v) => (DELIVERABLES.includes(v) ? (v === 'document' ? v : null) : fail('invalid', `deliverable must be ${DELIVERABLES.join(' or ')}`));

/** The states board-edit changes a task's deliverable in: nothing of it waits for a verdict (T158). */
const DELIVERABLE_STATES = ['new', 'ready', 'doing', 'changes'];

/** board-edit's inputs: the task field each one corrects, and what a value must be (T158). */
const EDITS = {
    title: ['title', (v) => text(v, 'title')],
    ticket: ['ticket_path', (v) => text(v, 'ticket')],
    constraints: ['constraints', (v) => text(v, 'constraints')],
    base: ['base_commit', (v) => (COMMIT.test(v ?? '') ? v : fail('invalid', 'base must be a full commit hash'))],
    priority: ['priority', (v) => (Number.isInteger(v) ? v : fail('invalid', 'priority must be an integer'))],
    deliverable: ['deliverable', deliverableOf],
};

/** A waiting task's brief as an answer or a cancel keeps it: the `waiting` object without the state it came from. */
const briefOf = ({ resume_state: _, ...asked }) => asked;

/** What board-decision-edit changes of a brief (T203); a decision of board-ask has its `tasks` too. */
const BRIEF_FIELDS = ['question', 'context', 'options', 'recommendation', 'impact', 'refs'];
/** A stored brief as brief() takes one: an option's detail left out is stored as ''. */
const asInput = (stored) => ({ ...stored, options: stored.options?.map((o) => ({ ...o, detail: o.detail || null })) });
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

export function createBoard({ store, roster, actor, now, git, notify = async () => [], event = async () => true }) {
    const team = () => roster();
    const names = () => team().map((w) => w.name);
    const pms = () => pmsOf(team());
    const isPm = (name) => pms().includes(name);
    const member = (name, what) => (names().includes(name) ? name : fail('invalid', `${what} '${name}' is not in the team`));
    /** The line when the reviewer is pm or missing, so pm judges its own work; a team with no roles has no one else to ask. */
    const reviewerWarning = (reviewer, id) => {
        if (pms().length === names().length) return null;
        if (!reviewer) return `no reviewer: pm judges ${id}; name a worker other than pm`;
        return pms().includes(reviewer) ? `reviewer ${reviewer} is the team's pm, who also plans the work; name a worker other than pm` : null;
    };
    /** Open decisions `name` asked: board-ask's open ones and the tasks waiting on a board-wait. */
    const openAsked = async (name) => (await store.list('decision', {})).filter((d) => d.state === 'open' && d.created_by === name).length
        + (await store.list('task', {})).filter((t) => t.state === 'waiting' && t.waiting?.asked_by === name).length;
    const needPm = () => { if (!isPm(actor)) fail('forbidden', `${actor} is not the team's pm`); };

    async function attempt(build) {
        for (let i = 1; ; i++) {
            const plan = await build();
            try {
                const applied = await store.apply(plan.changes);
                return { plan, applied };
            } catch (err) {
                if (err?.code !== 'conflict') throw err;
                if (i === ATTEMPTS) fail('conflict', `the board changed under this command ${ATTEMPTS} times; try again (${err.message})`);
            }
        }
    }

    /** Applies a planned command, then notifies and logs the event; failures there are warnings. */
    async function run(build) {
        if (!names().includes(actor)) fail('forbidden', `${actor} is not in the team`);
        const { plan, applied } = await attempt(build);
        const warnings = plan.warning ? [plan.warning] : [];
        const to = [...new Set(plan.notify ?? [])].filter((n) => n && n !== actor);
        // the change's event first, then its notices, so a notice's refusal follows what it was about (T65)
        try {
            const ok = await event({ worker: actor, action: plan.action, kind: plan.kind, ref: plan.ref, log_seq: applied.log_seq, ...(plan.states ?? {}) });
            if (!ok) warnings.push('event not logged');
        } catch (err) { warnings.push(`event: ${err.message}`); }
        if (to.length) {
            try { warnings.push(...(await notify(to, plan.ref, plan.action))); } catch (err) { warnings.push(`notify: ${err.message}`); }
        }
        // `warning` is what went wrong after the write; `warnings` is advice on the input (E23 to E25), one line each
        const advice = (plan.warnings ?? []).filter(Boolean);
        return {
            ok: true, ...plan.result(applied), notified: to,
            ...(warnings.length ? { warning: warnings.join('; ') } : {}), ...(advice.length ? { warnings: advice } : {}),
        };
    }

    /** The user's choice: one of the options' labels, 기타, or 철회 where it may close the question. */
    function choiceOf(input, options, { withdraw }) {
        const labels = [...options.map((o) => o.label), OTHER_CHOICE, ...(withdraw ? [WITHDRAWN] : [])];
        const picked = typeof input.chosen === 'string' ? input.chosen.trim() : null;
        const chosen = labels.includes(picked) ? picked : fail('invalid', `chosen must be one of ${labels.join(', ')}`);
        return { chosen, answer: text(input.answer, 'answer'), answered_by: actor, answered_at: now() };
    }

    async function answerDecision(input) {
        const d = (await store.get('decision', input.id)) ?? fail('not-found', `no decision ${input.id}`);
        if (d.state !== 'open') fail('invalid-transition', `${d.id} is already answered`);
        const answer = choiceOf(input, d.brief.options, { withdraw: true });
        return {
            action: 'answer', kind: 'decision', ref: d.id,
            changes: {
                updates: [touch('decision', d, { state: 'answered', answer })],
                log: [log('answer', 'decision', d.id, { detail: { question: d.brief.question, chosen: answer.chosen, answer: answer.answer } })],
            },
            notify: [d.created_by],
            result: () => ({ decision: { ...d, state: 'answered', answer, ...stamp(), version: d.version + 1 } }),
        };
    }

    const stamp = () => ({ updated_at: now(), updated_by: actor });
    const created = () => ({ created_at: now(), created_by: actor });
    const log = (action, kind, ref, extra = {}) => ({ at: now(), actor, action, kind, ref, ...extra });
    const touch = (kind, row, patch = {}) => ({ kind, key: row.id, expect_version: row.version, patch: { ...patch, ...stamp() } });

    async function getTask(id) {
        return (await store.get('task', text(id, 'id'))) ?? fail('not-found', `no task ${id}`);
    }
    async function family(task) {
        const rootId = task.parent_id ?? task.id;
        const root = rootId === task.id ? task : await store.get('task', rootId);
        const derived = await store.list('task', { parent_id: rootId });
        return { root, tasks: [root, ...derived] };
    }
    /** The root lock, when the task is derived (the task's own update locks a root). */
    const rootLock = (task, fam) => (task.parent_id ? [touch('task', fam.root)] : []);
    async function approved(landingId) {
        return (await store.list('verdict', { landing_id: landingId, verdict: 'approve' })).length > 0;
    }
    async function familyFindings(fam) {
        return store.list('finding', { task_id: fam.tasks.map((t) => t.id) });
    }
    /**
     * Locks for findings outside the family a write already locks: each one's task and, for a derived task, its
     * root, once each. `locked` holds the task ids the write locks already.
     */
    async function outsideLocks(findings, locked) {
        const updates = [];
        const lock = (t) => { if (!locked.has(t.id)) { locked.add(t.id); updates.push(touch('task', t)); } };
        for (const f of findings) {
            const t = await getTask(f.task_id);
            lock(t);
            if (t.parent_id) lock(await getTask(t.parent_id));
        }
        return updates;
    }
    const judgesOf = (task) => (task.reviewer ? [task.reviewer] : pms());
    /**
     * A landing with no commit fixes a document task's findings only (R8 S1): a task that delivers commits has
     * its findings fixed by commits, or it would pass review with the commit that was found wanting.
     */
    async function reportFixes(f, what) {
        const of = await getTask(f.task_id);
        if (!isDocument(of)) fail('invalid', `${what}: ${f.id} is a finding of ${of.id}, which delivers commits; a report alone does not fix it`);
    }

    return {
        /** board-add: a task, new or ready; a derived task locks its parent. */
        add: (input = {}) => run(async () => {
            needPm();
            const title = text(input.title, 'title');
            const assignee = input.assignee ? member(input.assignee, 'assignee') : null;
            const reviewer = input.reviewer ? member(input.reviewer, 'reviewer') : null;
            if (assignee && assignee === reviewer) fail('invalid', `${assignee} cannot review their own task`);
            if (input.base !== undefined && !COMMIT.test(input.base)) fail('invalid', 'base must be a full commit hash');
            const deliverable = input.deliverable === undefined ? null : deliverableOf(input.deliverable);
            const priority = input.priority ?? 100;
            if (!Number.isInteger(priority)) fail('invalid', 'priority must be an integer');
            const tasks = await store.list('task', {});
            const all = tasks.map((t) => t.id);
            const updates = [];
            let id = input.id;
            let parent = null;
            if (input.parent) {
                parent = await getTask(input.parent);
                if (parent.parent_id) fail('invalid', `${parent.id} is itself derived from ${parent.parent_id}; derive from ${parent.parent_id}`);
                if (parent.state === 'cancelled') fail('invalid', `${parent.id} is cancelled`);
                updates.push(touch('task', parent));
                id ??= nextDerived(parent.id, all);
            }
            id ??= nextNumbered('T', all);
            if (!TASK_ID.test(id)) fail('invalid', `task id '${id}' must match ${TASK_ID}`);
            if (input.id && all.includes(id)) fail('invalid', `task ${id} exists`);
            const state = assignee ? 'ready' : 'new';
            const row = {
                id, parent_id: parent?.id ?? null, title, ticket_path: input.ticket ?? null, state, assignee, reviewer,
                priority, base_commit: input.base ?? null, constraints: input.constraints ?? null, deliverable,
                assigned_at: assignee ? now() : null, ...created(),
            };
            return {
                action: 'add', kind: 'task', ref: id, states: { state_to: state },
                changes: { creates: [{ kind: 'task', row }], updates, log: [log('add', 'task', id, { state_to: state })] },
                notify: [assignee],
                warning: assignee && loadWarning([...tasks, row], team(), assignee),
                warnings: [reviewerWarning(reviewer, id)],
                result: () => ({ task: { ...row, version: 1 } }),
            };
        }),

        /**
         * board-edit: pm corrects what an unfinished task says (T158): its title, ticket, constraints, base, priority,
         * or whether it is a document task. Who works on it and who judges it are board-assign's. The state stays, and
         * so does updated_at, which says since when (as board-progress leaves it); the log keeps what changed.
         */
        edit: (input = {}) => run(async () => {
            needPm();
            const task = await getTask(input.id);
            move('edit', task);
            const { id: _, ...given } = input;
            const unknown = Object.keys(given).filter((k) => !Object.hasOwn(EDITS, k));
            if (unknown.length) fail('invalid', `board-edit corrects ${Object.keys(EDITS).join(', ')}; not ${unknown.join(', ')}`);
            const patch = {}, changed = {};
            for (const [name, value] of Object.entries(given)) {
                const [field, check] = EDITS[name];
                const to = check(value);
                if (to === task[field]) continue;
                patch[field] = to;
                changed[field] = { from: task[field], to };
            }
            if (!Object.keys(patch).length) fail('invalid', `nothing to change: give ${Object.keys(EDITS).join(', ')} with a new value`);
            if ('deliverable' in patch) {
                // what is handed in is settled before it is: a landing waiting for its verdict is judged as it was landed
                if (!DELIVERABLE_STATES.includes(task.state)) fail('invalid', `${task.id} is ${task.state}; deliverable changes in ${DELIVERABLE_STATES.join(', ')}`);
                // a task that landed commits is judged by them: it is no document task
                if (patch.deliverable && (await store.list('landing', { task_id: task.id })).some((l) => l.commit)) {
                    fail('invalid', `${task.id} landed commits; it cannot become a document task`);
                }
            }
            return {
                action: 'edit', kind: 'task', ref: task.id,
                changes: { updates: [{ kind: 'task', key: task.id, expect_version: task.version, patch }], log: [log('edit', 'task', task.id, { detail: { changed } })] },
                notify: [task.assignee, ...(task.state === 'review' || task.waiting?.resume_state === 'review' ? judgesOf(task) : [])],
                result: () => ({ task: { ...task, ...patch, version: task.version + 1 } }),
            };
        }),

        /**
         * board-assign, three forms: with `assignee`, (re)assign → ready; on a held task without `assignee`,
         * ask for review again → review; otherwise change the reviewer, the state staying.
         */
        assign: (input = {}) => run(async () => {
            needPm();
            const task = await getTask(input.id);
            const assignee = input.assignee !== undefined ? member(input.assignee, 'assignee') : task.assignee;
            const reviewer = input.reviewer !== undefined ? (input.reviewer && member(input.reviewer, 'reviewer')) || null : task.reviewer;
            if (input.assignee === undefined && input.reviewer === undefined && task.state !== 'held') {
                fail('invalid', 'give assignee or reviewer');
            }
            if (assignee && assignee === reviewer) fail('invalid', `${assignee} cannot review their own task`);
            if (input.reviewer !== undefined && assignee && judgesOf({ reviewer }).every((j) => j === assignee)) {
                fail('invalid', `without a reviewer only ${assignee}, the assignee, could judge ${task.id}; name another reviewer`);
            }
            const form = input.assignee !== undefined ? 'reassign' : task.state === 'held' ? 'rereview' : 'reviewer';
            const state = move(form, task);
            const patch = { state, assignee, reviewer, ...(form === 'reassign' ? { assigned_at: now() } : {}) };
            const notify = form === 'reassign' ? [assignee, task.assignee]
                : form === 'rereview' ? judgesOf({ reviewer })
                    : task.state === 'review' ? [reviewer, task.reviewer] : [];
            const states = state !== task.state ? { state_from: task.state, state_to: state } : {};
            const addsLoad = form === 'reassign' && (assignee !== task.assignee || !IN_HAND.includes(task.state));
            const after = (t) => (t.id === task.id ? { ...t, ...patch } : t);
            return {
                action: 'assign', kind: 'task', ref: task.id, states,
                warning: addsLoad && loadWarning((await store.list('task', {})).map(after), team(), assignee),
                warnings: [input.reviewer !== undefined && reviewerWarning(reviewer, task.id)],
                changes: { updates: [touch('task', task, patch)], log: [log('assign', 'task', task.id, { ...states, detail: { form, assignee, reviewer, was: task.assignee } })] },
                notify,
                result: () => ({ task: { ...task, ...patch, ...stamp(), version: task.version + 1 } }),
            };
        }),

        /**
         * board-wait: the task waits for the user's decision (T115). pm or its assignee asks with a decision brief;
         * the task keeps it and the state it leaves, and lands, takes and verdicts wait for board-answer.
         */
        wait: (input = {}) => run(async () => {
            const task = await getTask(input.id);
            if (!isPm(actor) && task.assignee !== actor) fail('forbidden', `${actor} is neither the team's pm nor ${task.id}'s assignee`);
            move('wait', task);
            // one time for the brief and the log entry: the decision list reads either (T148, R4a L1)
            const at = now();
            const waiting = { ...brief(input), asked_by: actor, asked_at: at, resume_state: task.state };
            const { question } = waiting;
            const states = { state_from: task.state, state_to: 'waiting' };
            return {
                action: 'wait', kind: 'task', ref: task.id, states,
                changes: { updates: [touch('task', task, { state: 'waiting', waiting })], log: [log('wait', 'task', task.id, { at, ...states, detail: { question } })] },
                notify: [...pms(), task.assignee, task.reviewer],
                warnings: briefWarnings(waiting, actor, (await openAsked(actor)) + 1),
                result: () => ({ task: { ...task, state: 'waiting', waiting, ...stamp(), version: task.version + 1 } }),
            };
        }),

        /**
         * board-answer: pm records the user's decision, the option chosen (or 기타) and the user's words; the task
         * goes back to the state it waited from (T115).
         */
        answer: (input = {}) => run(async () => {
            needPm();
            if (DECISION_ID.test(input.id ?? '')) return answerDecision(input);
            const task = await getTask(input.id);
            move('answer', task);
            const labels = [...task.waiting.options.map((o) => o.label), OTHER_CHOICE];
            const picked = typeof input.chosen === 'string' ? input.chosen.trim() : null;
            const chosen = labels.includes(picked) ? picked : fail('invalid', `chosen must be one of ${labels.join(', ')}`);
            const answer = text(input.answer, 'answer');
            const state = task.waiting.resume_state;
            const decision = { question: task.waiting.question, chosen, answer, answered_by: actor, answered_at: now(), brief: briefOf(task.waiting) };
            const states = { state_from: 'waiting', state_to: state };
            return {
                action: 'answer', kind: 'task', ref: task.id, states,
                changes: { updates: [touch('task', task, { state, waiting: null })], log: [log('answer', 'task', task.id, { ...states, detail: decision })] },
                notify: [task.assignee, task.reviewer],
                result: () => ({ task: { ...task, state, waiting: null, ...stamp(), version: task.version + 1 }, decision }),
            };
        }),

        /**
         * board-progress: the assignee says where the work is (T127): ticket item `item` (1 up, 0 for work outside
         * the items), a sentence or two, and whether that item is done. A log entry only; nobody is told. The task
         * row's version goes up so a land or a cancel in between is seen, but not its updated_at: the app counts how
         * long a task has been in its state from it (R47 S1).
         */
        progress: (input = {}) => run(async () => {
            const task = await getTask(input.id);
            if (task.assignee !== actor) fail('forbidden', `${task.id} is assigned to ${task.assignee ?? 'nobody'}, not ${actor}`);
            if (!PROGRESS_STATES.includes(task.state)) fail('invalid-transition', `${task.id} is ${task.state}; progress needs ${PROGRESS_STATES.join(' or ')}`);
            const item = Number.isInteger(input.item) && input.item >= 0 ? input.item : fail('invalid', 'item must be the ticket item\'s number (1 up), or 0 for work outside the items');
            const note = text(input.note, 'note');
            const done = typeof input.done === 'boolean' ? input.done : fail('invalid', 'done must be true or false');
            const entry = { item, note, done };
            const at = now();
            return {
                action: 'progress', kind: 'task', ref: task.id,
                changes: { updates: [{ kind: 'task', key: task.id, expect_version: task.version, patch: {} }], log: [log('progress', 'task', task.id, { at, detail: entry })] },
                notify: [],
                result: () => ({ progress: { ...entry, by: actor, at } }),
            };
        }),

        /** board-take: the assignee starts (or starts fixing after `changes`). */
        take: (input = {}) => run(async () => {
            const task = await getTask(input.id);
            if (task.assignee !== actor) fail('forbidden', `${task.id} is assigned to ${task.assignee ?? 'nobody'}, not ${actor}`);
            const state = move('take', task);
            return {
                action: 'take', kind: 'task', ref: task.id, states: { state_from: task.state, state_to: state },
                changes: { updates: [touch('task', task, { state })], log: [log('take', 'task', task.id, { state_from: task.state, state_to: state })] },
                notify: [],
                result: () => ({ task: { ...task, state, ...stamp(), version: task.version + 1 } }),
            };
        }),

        /**
         * board-land: a review request. Resubmitting supersedes the open landing and moves the fixed_in of
         * findings that pointed at it. `closes` findings become fixed in this landing.
         */
        land: (input = {}) => run(async () => {
            const task = await getTask(input.id);
            if (task.assignee !== actor) fail('forbidden', `${task.id} is assigned to ${task.assignee ?? 'nobody'}, not ${actor}`);
            const resubmit = task.state === 'review';
            const state = move(resubmit ? 'resubmit' : 'land', task);
            if (!task.reviewer && isPm(actor)) fail('invalid', `${actor} would judge their own work; give ${task.id} a reviewer first`);
            // a document task hands in its report alone (T158): the landing's commit fields stay, empty
            const doc = isDocument(task);
            const stray = doc ? ['commit', 'base', 'commits'].filter((k) => input[k] !== undefined) : [];
            if (stray.length) fail('invalid', `${task.id} is a document task: it lands a report and no ${stray.join(', ')}`);
            const repo = doc ? '' : text(input.repo, 'repo');
            const commit = doc ? '' : COMMIT.test(input.commit ?? '') ? input.commit : fail('invalid', 'commit must be a full commit hash');
            const check = { cmd: text(input.check?.cmd, 'check.cmd'), result: text(input.check?.result, 'check.result') };
            const focus = texts(input.focus, 'focus', { nonEmpty: true });
            const closes = texts(input.closes ?? [], 'closes');
            const report = text(input.report, 'report');
            // a suggestion: the review report path is the reviewer's to choose (R71 R2)
            const reviewReport = input.review_report == null ? null : text(input.review_report, 'review_report');

            const fam = await family(task);
            const landings = (await store.list('landing', { task_id: fam.tasks.map((t) => t.id) }))
                .sort((x, y) => (x.created_at < y.created_at ? -1 : x.created_at > y.created_at ? 1 : 0));
            let base = doc ? '' : input.base;
            if (base === undefined) {
                // the last approved commit: a document task's landing has none
                for (const l of landings) if (l.commit && await approved(l.id)) base = l.commit;
                base ??= task.base_commit ?? fail('invalid', `${task.id} has no base: give base`);
            }
            let range = { commits: [] }, commits = [];
            if (!doc) {
                if (!COMMIT.test(base)) fail('invalid', 'base must be a full commit hash');
                range = git ? await git.range(repo, base, commit) : fail('invalid', 'no git to check the range with');
                if (!range.ancestor) fail('invalid', `${base} is not an ancestor of ${commit}`);
                commits = input.commits === undefined ? range.commits : texts(input.commits, 'commits');
                const outside = commits.filter((c) => !range.commits.includes(c));
                if (outside.length) fail('invalid', `not in ${base}..${commit}: ${outside.join(', ')}`);
                if (!commits.includes(commit)) fail('invalid', `commits must include ${commit}`);
            }

            // any open finding of the board: a fix made in this work may be another family's (T87)
            const closing = [];
            for (const fid of new Set(closes)) {
                const f = await store.get('finding', fid);
                if (!f || !FIXABLE.includes(f.state)) fail('invalid', `closes: ${fid} is not an open or backlog finding on the board`);
                if (doc) await reportFixes(f, 'closes');
                if (f.state === 'open') closing.push(f);
            }
            const own = landings.filter((l) => l.task_id === task.id);
            const id = `${task.id}#${own.length + 1}`;
            const previous = own.find((l) => l.superseded_by === null) ?? null;
            const updates = [touch('task', task, { state }), ...rootLock(task, fam)];
            if (previous) updates.push(touch('landing', previous, { superseded_by: id }));
            // the fixes the superseded landing made, wherever their findings are, now point at this one
            const moving = previous ? (await store.list('finding', { fixed_in: previous.id })).filter((f) => f.state === 'fixed') : [];
            for (const f of closing) updates.push(touch('finding', f, { state: 'fixed', fixed_in: id }));
            for (const f of moving) updates.push(touch('finding', f, { fixed_in: id }));
            const famIds = new Set(fam.tasks.map((t) => t.id));
            updates.push(...await outsideLocks([...closing, ...moving].filter((f) => !famIds.has(f.task_id)), new Set(famIds)));
            // whoever works on or judges a finding's own task hears that another family's work fixed it (R15 L1); a
            // task with no reviewer is judged by pm, who hears it then (R44 L3)
            const toldOutside = [];
            for (const f of closing.filter((x) => !famIds.has(x.task_id))) {
                const t = await getTask(f.task_id);
                toldOutside.push(t.assignee, ...judgesOf(t));
            }
            const fixed = closing.map((f) => f.id);
            const row = {
                id, task_id: task.id, repo, commit, base_commit: base, commits, check_cmd: check.cmd, check_result: check.result,
                focus, closes, report_path: report, review_report_path: reviewReport, deployed: input.deployed ?? null,
                left_out: range.commits.filter((c) => !commits.includes(c)), ...created(),
            };
            const states = { state_from: task.state, state_to: state };
            return {
                action: 'land', kind: 'landing', ref: id, states,
                changes: { creates: [{ kind: 'landing', row }], updates, log: [log('land', 'landing', id, { ...states, detail: { task: task.id, superseded: previous?.id ?? null } })] },
                // the judge only: pm hears of a reviewed task at its verdict (R70 L2); and the families it fixes for
                notify: [...judgesOf(task), ...toldOutside],
                result: () => ({ task: { ...task, state }, landing: { ...row, superseded_by: null, version: 1 }, fixed }),
            };
        }),

        /** board-verdict: approve → done, changes → changes, hold → held. Opens findings, may reopen fixed ones. */
        verdict: (input = {}) => run(async () => {
            const landing = (await store.get('landing', text(input.landing, 'landing'))) ?? fail('not-found', `no landing ${input.landing}`);
            const task = await getTask(landing.task_id);
            if (landing.superseded_by) fail('stale-landing', `${landing.id} was superseded by ${landing.superseded_by}`);
            if (!judgesOf(task).includes(actor)) fail('forbidden', `${actor} does not judge ${task.id} (${judgesOf(task).join(', ')})`);
            if (task.assignee === actor) fail('forbidden', `${actor} cannot judge their own work`);
            const verdict = Object.hasOwn(VERDICTS, input.verdict) ? input.verdict : fail('invalid', `verdict must be ${Object.keys(VERDICTS).join(', ')}`);
            move('verdict', task);
            const state = VERDICTS[verdict];
            if ((input.verified_commit ?? '') !== landing.commit) fail('stale-landing', `${landing.id} is ${landing.commit}; verified_commit is ${input.verified_commit}`);
            const report = input.report === undefined
                ? landing.review_report_path ?? fail('invalid', `report is required: ${landing.id} suggests no review report path`)
                : text(input.report, 'report');
            const rerun = { cmd: text(input.rerun?.cmd, 'rerun.cmd'), result: text(input.rerun?.result, 'rerun.result') };
            const raised = input.findings ?? [];
            if (!Array.isArray(raised)) fail('invalid', 'findings must be a list');
            const reopen = texts(input.reopen ?? [], 'reopen');

            const fam = await family(task);
            const famIds = fam.tasks.map((t) => t.id);
            const all = await store.list('verdict', {});
            const familyLandings = await store.list('landing', { task_id: famIds });
            const famLandings = new Set(familyLandings.map((l) => l.id));
            // R68a R1: whoever landed one of these commits, in any landing of the family, does not approve them
            const own = new Set(familyLandings.filter((l) => l.created_by === actor).flatMap((l) => l.commits));
            const mine = landing.commits.filter((c) => own.has(c));
            if (mine.length) fail('forbidden', `${actor} landed ${mine.join(', ')} and cannot judge it`);
            // a report has no commits to tell whose it is (R8 S2): whoever landed a report of this task does not judge one
            const reported = familyLandings.find((l) => l.task_id === task.id && !l.commit && l.created_by === actor);
            if (!landing.commit && reported) fail('forbidden', `${actor} landed ${reported.id}, a report of ${task.id}, and cannot judge it`);
            const famVerdicts = all.filter((v) => famLandings.has(v.landing_id)).map((v) => v.id);
            const vid = nextVerdictId(all.map((v) => v.id), famVerdicts);

            const codes = new Set();
            const newFindings = raised.map((f) => {
                const code = FINDING_CODE.test(f?.code ?? '') ? f.code : fail('invalid', `finding code '${f?.code}' must match ${FINDING_CODE}`);
                if (codes.has(code)) fail('invalid', `finding ${code} twice`);
                codes.add(code);
                if (!SEVERITIES.includes(f.severity)) fail('invalid', `severity must be ${SEVERITIES.join(', ')}`);
                return {
                    id: `${vid} ${code}`, verdict_id: vid, task_id: task.id, severity: f.severity,
                    summary: text(f.summary, 'summary'), repro: text(f.repro, 'repro'), state: 'open', ...created(),
                };
            });
            const findings = await familyFindings(fam);
            const pending = await pendingBacklogCloses(store, landing);
            const fixing = verdict === 'approve' ? pending.filter((f) => !reopen.includes(f.id)) : [];
            const reopened = [];
            for (const fid of reopen) {
                if (pending.some((f) => f.id === fid)) continue;
                // the family's fixed findings, and those this landing fixed in another family (T87)
                const f = findings.find((x) => x.id === fid) ?? await store.get('finding', fid);
                const ours = f && (famIds.includes(f.task_id) || f.fixed_in === landing.id);
                if (!ours || f.state !== 'fixed') fail('invalid', `reopen: ${fid} is not a fixed finding of ${fam.root.id}'s family or of ${landing.id}`);
                reopened.push(f);
            }
            if (verdict === 'approve') {
                // a fix from another family's landing counts only once that landing is approved (T87)
                const approvedIds = new Set(all.filter((v) => v.verdict === 'approve').map((v) => v.landing_id));
                const pendingOutside = (f) => f.state === 'fixed' && !famLandings.has(f.fixed_in) && !approvedIds.has(f.fixed_in);
                const must = [...findings.filter((f) => f.state === 'open' || reopened.some((r) => r.id === f.id) || pendingOutside(f)), ...newFindings]
                    .filter((f) => f.severity === 'must').map((f) => f.id);
                if (must.length) fail('invalid', `cannot approve with open must findings in the family: ${must.join(', ')}`);
            }
            const reopenLocks = await outsideLocks([...reopened, ...fixing].filter((f) => !famIds.includes(f.task_id)), new Set(famIds));
            const row = {
                id: vid, landing_id: landing.id, verdict, verified_commit: landing.commit, report_path: report,
                rerun_cmd: rerun.cmd, rerun_result: rerun.result, side_notes: input.side_notes ?? null, ...created(),
            };
            const states = { state_from: task.state, state_to: state };
            return {
                action: 'verdict', kind: 'verdict', ref: vid, states,
                changes: {
                    creates: [{ kind: 'verdict', row }, ...newFindings.map((f) => ({ kind: 'finding', row: f }))],
                    updates: [
                        touch('task', task, { state }), touch('landing', landing), ...rootLock(task, fam),
                        ...reopened.map((f) => touch('finding', f, { state: 'open', fixed_in: null })),
                        ...fixing.map((f) => touch('finding', f, { state: 'fixed', fixed_in: landing.id })), ...reopenLocks,
                    ],
                    log: [log('verdict', 'verdict', vid, { ...states, detail: { landing: landing.id, verdict } })],
                },
                notify: [...pms(), task.assignee],
                result: () => ({ verdict: row, task: { ...task, state }, findings: newFindings.map((f) => f.id), reopened: reopened.map((f) => f.id), fixed: fixing.map((f) => f.id) }),
            };
        }),

        /** board-finding: settle or reopen a finding (FINDING_MOVES in rules.js). */
        finding: (input = {}) => run(async () => {
            const f = (await store.get('finding', text(input.id, 'id'))) ?? fail('not-found', `no finding ${input.id}`);
            const to = text(input.state, 'state');
            const rule = FINDING_MOVES.find((r) => r.from.includes(f.state) && r.to.includes(to) && (r.who === 'pm' ? isPm(actor) : true));
            const task = await getTask(f.task_id);
            const fam = await family(task);
            if (!rule) {
                const any = FINDING_MOVES.some((r) => r.from.includes(f.state) && r.to.includes(to));
                fail(any ? 'forbidden' : 'invalid-transition', `${f.id}: ${f.state} → ${to} ${any ? `is not ${actor}'s to make` : 'is not a move'}`);
            }
            if (rule.who === 'reviewer') {
                const verdict = await store.get('verdict', f.verdict_id);
                if (actor !== verdict?.created_by && actor !== task.reviewer) fail('forbidden', `${actor} did not raise ${f.id}`);
            }
            if (to === 'open' && fam.tasks.every((t) => TERMINAL.includes(t.state))) {
                fail('invalid', `${fam.root.id}'s family has no unfinished task to fix ${f.id} in; add a derived task first`);
            }
            let fixedIn = null;
            if (to === 'fixed') {
                // after the fact, so only a fix a verdict already approved: the review it would have had is done
                const landing = (await store.get('landing', text(input.landing, 'landing'))) ?? fail('not-found', `no landing ${input.landing}`);
                if (!(await approved(landing.id))) fail('invalid', `${landing.id} has no approve; record a fix only of an approved landing`);
                if (!landing.commit) await reportFixes(f, landing.id);
                fixedIn = landing.id;
            }
            const patch = { state: to, ...(to === 'open' ? { fixed_in: null } : to === 'fixed' ? { fixed_in: fixedIn } : {}) };
            return {
                action: 'finding', kind: 'finding', ref: f.id, states: { state_from: f.state, state_to: to },
                changes: {
                    updates: [touch('finding', f, patch), touch('task', task), ...(task.parent_id ? [touch('task', fam.root)] : [])],
                    log: [log('finding', 'finding', f.id, { state_from: f.state, state_to: to })],
                },
                notify: [],
                result: () => ({ finding: { ...f, ...patch } }),
            };
        }),

        /**
         * board-cancel. The task's own unsettled findings move to `findings` (a settled state) with it; a fix
         * it made to another task's finding, never approved, goes back to open.
         */
        cancel: (input = {}) => run(async () => {
            needPm();
            const task = await getTask(input.id);
            const state = move('cancel', task);
            const fam = await family(task);
            const findings = await familyFindings(fam);
            const ownLandings = new Set((await store.list('landing', { task_id: task.id })).map((l) => l.id));
            const updates = [touch('task', task, { state, waiting: null }), ...rootLock(task, fam)];
            const moved = [];
            // its unapproved fixes of other families' findings go back to open too (T87)
            const famIds = new Set(fam.tasks.map((t) => t.id));
            const outside = [];
            for (const f of await store.list('finding', { fixed_in: [...ownLandings] })) {
                if (famIds.has(f.task_id) || f.state !== 'fixed' || await approved(f.fixed_in)) continue;
                updates.push(touch('finding', f, { state: 'open', fixed_in: null }));
                moved.push(f.id);
                outside.push(f);
            }
            updates.push(...await outsideLocks(outside, new Set(famIds)));
            for (const f of findings) {
                const unapprovedFix = f.state === 'fixed' && !(await approved(f.fixed_in));
                if (f.task_id === task.id && (f.state === 'open' || unapprovedFix)) {
                    if (!SETTLED.includes(input.findings)) {
                        fail('invalid', `${task.id} has unsettled findings; give findings: ${SETTLED.join(' | ')}`);
                    }
                    updates.push(touch('finding', f, { state: input.findings }));
                    moved.push(f.id);
                } else if (unapprovedFix && ownLandings.has(f.fixed_in)) {
                    updates.push(touch('finding', f, { state: 'open', fixed_in: null }));
                    moved.push(f.id);
                }
            }
            const states = { state_from: task.state, state_to: state };
            return {
                action: 'cancel', kind: 'task', ref: task.id, states,
                changes: { updates, log: [log('cancel', 'task', task.id, { ...states, detail: { reason: input.reason ?? null, ...(task.waiting ? { brief: briefOf(task.waiting) } : {}) } })] },
                notify: [task.assignee, ...(task.state === 'review' || task.waiting?.resume_state === 'review' ? judgesOf(task) : [])],
                result: () => ({ task: { ...task, state, waiting: null }, findings: moved }),
            };
        }),

        /**
         * board-ask: a decision for the user that stops no task (T146). Anyone in the team asks with a decision brief
         * and the tasks it serves, which go on as they are; pm is told. With `answered` {chosen, answer}, pm records
         * a decision the user already made: question and answer at once, one option or more.
         */
        ask: (input = {}) => run(async () => {
            const answered = input.answered ?? null;
            if (answered !== null) {
                if (typeof answered !== 'object' || Array.isArray(answered)) fail('invalid', 'answered must be {chosen, answer}');
                needPm();
            }
            const asked = brief(input, { least: answered ? 1 : 2 });
            const tasks = input.tasks == null ? [] : texts(input.tasks, 'tasks');
            for (const id of tasks) await getTask(id);
            const numbers = (await store.list('decision', {})).map((d) => Number(DECISION_ID.exec(d.id)?.[1] ?? 0));
            const id = `D#${Math.max(0, ...numbers) + 1}`;
            const answer = answered ? choiceOf(answered, asked.options, { withdraw: false }) : null;
            const row = { id, tasks: [...new Set(tasks)], brief: asked, state: answer ? 'answered' : 'open', answer, ...created() };
            const logs = [
                log('ask', 'decision', id, { detail: { question: asked.question, tasks: row.tasks } }),
                ...(answer ? [log('answer', 'decision', id, { detail: { question: asked.question, chosen: answer.chosen, answer: answer.answer } })] : []),
            ];
            return {
                action: 'ask', kind: 'decision', ref: id,
                changes: { creates: [{ kind: 'decision', row }], log: logs },
                notify: answer ? [] : pms(),
                warnings: answer ? [] : briefWarnings(asked, actor, (await openAsked(actor)) + 1),
                result: () => ({ decision: { ...row, updated_at: null, updated_by: null, version: 1 } }),
            };
        }),

        /**
         * board-decision-edit: an open decision says what the talk about it has come to (T203). `id` is a decision
         * D#…, or the task whose wait it is. pm or the worker who asked gives the brief's fields that change (and,
         * for a D#…, `tasks`); the rest stay, and the brief left is checked as board-ask checks one. The log keeps
         * what each field was under the decision's id (a wait's as the decision list gives it, T5:2); the other of pm and
         * the asker is told.
         */
        'decision-edit': (input = {}) => run(async () => {
            const { id, ...given } = input;
            const decision = DECISION_ID.test(id ?? '') ? (await store.get('decision', id)) ?? fail('not-found', `no decision ${id}`) : null;
            const task = decision ? null : await getTask(id);
            if (task) move('decision-edit', task);
            else if (decision.state !== 'open') {
                fail('invalid-transition', `${decision.id} is ${decision.answer?.chosen === WITHDRAWN ? 'withdrawn' : 'already answered'}; only an open decision is edited`);
            }
            const asker = task ? task.waiting.asked_by : decision.created_by;
            if (!isPm(actor) && asker !== actor) fail('forbidden', `${actor} is neither the team's pm nor the worker who asked ${id} (${asker})`);
            const fields = task ? BRIEF_FIELDS : [...BRIEF_FIELDS, 'tasks'];
            const unknown = Object.keys(given).filter((k) => !fields.includes(k));
            if (unknown.length) fail('invalid', `board-decision-edit changes ${fields.join(', ')} of ${id}; not ${unknown.join(', ')}`);
            const stored = task ? task.waiting : decision.brief;
            const was = { ...Object.fromEntries(BRIEF_FIELDS.map((f) => [f, stored[f]])), ...(decision ? { tasks: decision.tasks } : {}) };
            const { tasks: _, ...briefGiven } = given;
            const next = brief({ ...asInput(was), ...briefGiven });
            if (decision && 'tasks' in given) {
                next.tasks = [...new Set(given.tasks == null ? [] : texts(given.tasks, 'tasks'))];
                for (const t of next.tasks) await getTask(t);
            }
            const changed = Object.fromEntries(Object.keys(given).filter((f) => !same(was[f], next[f])).map((f) => [f, { from: was[f] ?? null, to: next[f] }]));
            if (!Object.keys(changed).length) fail('invalid', `nothing to change: give ${fields.join(', ')} with a new value`);
            const { tasks = null, ...edited } = next;
            const row = task ? { ...task, waiting: { ...task.waiting, ...edited } } : { ...decision, brief: edited, tasks: tasks ?? decision.tasks };
            const at = now();
            const patch = task ? { waiting: row.waiting } : { brief: row.brief, tasks: row.tasks, updated_at: at, updated_by: actor };
            const ref = task ? waitId(task.id, (await store.logOf([task.id])).filter((e) => e.kind === 'task' && e.action === 'wait').length) : decision.id;
            return {
                action: 'edit', kind: 'decision', ref,
                changes: {
                    updates: [{ kind: task ? 'task' : 'decision', key: id, expect_version: row.version, patch }],
                    log: [log('edit', 'decision', ref, { at, detail: { changed } })],
                },
                notify: [...pms(), asker],
                result: () => ({ [task ? 'task' : 'decision']: { ...row, ...patch, version: row.version + 1 }, changed: Object.keys(changed) }),
            };
        }),

        /** board-note: appended; locks nothing. */
        note: (input = {}) => run(async () => {
            const body = text(input.body, 'body');
            const task = input.id ? await getTask(input.id) : null;
            const to = input.to === undefined ? null : texts(input.to, 'to').map((n) => member(n, 'to'));
            const ref = task?.id ?? '-';
            return {
                action: 'note', kind: 'note', ref,
                changes: { creates: [{ kind: 'note', row: { task_id: task?.id ?? null, body, to, ...created() } }], log: [log('note', 'note', ref)] },
                notify: to ?? [],
                result: (applied) => ({ note: applied.seqs.note[0] }),
            };
        }),

        /** board-announce: to the whole team; locks nothing. */
        announce: (input = {}) => run(async () => {
            needPm();
            const body = text(input.body, 'body');
            return {
                action: 'announce', kind: 'announcement', ref: '-',
                changes: { creates: [{ kind: 'announcement', row: { body, ...created() } }], log: [log('announce', 'announcement', '-')] },
                notify: names(),
                result: (applied) => ({ announcement: applied.seqs.announcement[0] }),
            };
        }),
    };
}

export { BoardError };
