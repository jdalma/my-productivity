/**
 * The board's write commands (T63c, rfc/board-design.md §3, §4.1, §6.2). One function per command. Each
 * attempt reads, decides by the tables in rules.js, and applies one change set; a Conflict from the store
 * means someone changed what was read, so the attempt runs again from the read (3 attempts).
 *
 * The task row is the lock of its task (§4.1): every write that affects a task, its landings, verdicts or
 * findings updates the task row at the version it read, even when the state stays. Writes that look at or
 * change findings lock the family's root task too, since findings span the family.
 *
 * Ports (all injected, §1.1):
 *   store     the store contract (contract.js)
 *   roster    () => [{name, role}]
 *   actor     the worker acting (resolved from MY_TEAM_WORKER by compose)
 *   now       () => ISO time
 *   git       { range(repo, base, commit) => {ancestor, commits} } — land's checks (T63e implements it)
 *   notify    (to[], ref, action) => Promise<string[] warnings>, after the change is applied
 *   event     (fields) => Promise<boolean>, after the change is applied
 */

import {
    BoardError, COMMIT, FINDING_CODE, FINDING_MOVES, SETTLED, SEVERITIES, TASK_ID, TERMINAL, VERDICTS,
    fail, move, nextDerived, nextNumbered, pmsOf, verdictBase,
} from './rules.js';

const ATTEMPTS = 3;

const text = (v, name) => (typeof v === 'string' && v.trim() ? v : fail('invalid', `${name} is required`));
const texts = (v, name, { nonEmpty = false } = {}) => {
    if (!Array.isArray(v) || v.some((x) => typeof x !== 'string' || !x.trim())) fail('invalid', `${name} must be a list of strings`);
    if (nonEmpty && !v.length) fail('invalid', `${name} needs at least one item`);
    return v;
};

export function createBoard({ store, roster, actor, now, git, notify = async () => [], event = async () => true }) {
    const team = () => roster();
    const names = () => team().map((w) => w.name);
    const pms = () => pmsOf(team());
    const isPm = (name) => pms().includes(name);
    const member = (name, what) => (names().includes(name) ? name : fail('invalid', `${what} '${name}' is not in the team`));
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
        const warnings = [];
        const to = [...new Set(plan.notify ?? [])].filter((n) => n && n !== actor);
        if (to.length) {
            try { warnings.push(...(await notify(to, plan.ref, plan.action))); } catch (err) { warnings.push(`notify: ${err.message}`); }
        }
        try {
            const ok = await event({ worker: actor, action: plan.action, kind: plan.kind, ref: plan.ref, log_seq: applied.log_seq, ...(plan.states ?? {}) });
            if (!ok) warnings.push('event not logged');
        } catch (err) { warnings.push(`event: ${err.message}`); }
        return { ok: true, ...plan.result(applied), notified: to, ...(warnings.length ? { warning: warnings.join('; ') } : {}) };
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
    const judgesOf = (task) => (task.reviewer ? [task.reviewer] : pms());

    return {
        /** board-add: a task, new or ready; a derived task locks its parent (§4.1). */
        add: (input = {}) => run(async () => {
            needPm();
            const title = text(input.title, 'title');
            const assignee = input.assignee ? member(input.assignee, 'assignee') : null;
            const reviewer = input.reviewer ? member(input.reviewer, 'reviewer') : null;
            if (assignee && assignee === reviewer) fail('invalid', `${assignee} cannot review their own task`);
            if (input.base !== undefined && !COMMIT.test(input.base)) fail('invalid', 'base must be a full commit hash');
            const priority = input.priority ?? 100;
            if (!Number.isInteger(priority)) fail('invalid', 'priority must be an integer');
            const all = (await store.list('task', {})).map((t) => t.id);
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
            const state = assignee ? 'ready' : 'new';
            const row = {
                id, parent_id: parent?.id ?? null, title, ticket_path: input.ticket ?? null, state, assignee, reviewer,
                priority, base_commit: input.base ?? null, constraints: input.constraints ?? null,
                assigned_at: assignee ? now() : null, ...created(),
            };
            return {
                action: 'add', kind: 'task', ref: id, states: { state_to: state },
                changes: { creates: [{ kind: 'task', row }], updates, log: [log('add', 'task', id, { state_to: state })] },
                notify: [assignee],
                result: () => ({ task: { ...row, version: 1 } }),
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
            const form = input.assignee !== undefined ? 'reassign' : task.state === 'held' ? 'rereview' : 'reviewer';
            const state = move(form, task);
            const patch = { state, assignee, reviewer, ...(form === 'reassign' ? { assigned_at: now() } : {}) };
            const notify = form === 'reassign' ? [assignee, task.assignee]
                : form === 'rereview' ? judgesOf({ reviewer })
                    : task.state === 'review' ? [reviewer, task.reviewer] : [];
            const states = state !== task.state ? { state_from: task.state, state_to: state } : {};
            return {
                action: 'assign', kind: 'task', ref: task.id, states,
                changes: { updates: [touch('task', task, patch)], log: [log('assign', 'task', task.id, { ...states, detail: { form, assignee, reviewer, was: task.assignee } })] },
                notify,
                result: () => ({ task: { ...task, ...patch, ...stamp(), version: task.version + 1 } }),
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
            const repo = text(input.repo, 'repo');
            const commit = COMMIT.test(input.commit ?? '') ? input.commit : fail('invalid', 'commit must be a full commit hash');
            const check = { cmd: text(input.check?.cmd, 'check.cmd'), result: text(input.check?.result, 'check.result') };
            const focus = texts(input.focus, 'focus', { nonEmpty: true });
            const closes = texts(input.closes, 'closes');
            const report = text(input.report, 'report');
            const reviewReport = text(input.review_report, 'review_report');

            const fam = await family(task);
            const landings = (await store.list('landing', { task_id: fam.tasks.map((t) => t.id) }))
                .sort((x, y) => (x.created_at < y.created_at ? -1 : x.created_at > y.created_at ? 1 : 0));
            let base = input.base;
            if (base === undefined) {
                for (const l of landings) if (await approved(l.id)) base = l.commit;
                base ??= task.base_commit ?? fail('invalid', `${task.id} has no base: give base`);
            }
            if (!COMMIT.test(base)) fail('invalid', 'base must be a full commit hash');
            const range = git ? await git.range(repo, base, commit) : fail('invalid', 'no git to check the range with');
            if (!range.ancestor) fail('invalid', `${base} is not an ancestor of ${commit}`);
            const commits = input.commits === undefined ? range.commits : texts(input.commits, 'commits');
            const outside = commits.filter((c) => !range.commits.includes(c));
            if (outside.length) fail('invalid', `not in ${base}..${commit}: ${outside.join(', ')}`);
            if (!commits.includes(commit)) fail('invalid', `commits must include ${commit}`);

            const findings = await familyFindings(fam);
            for (const id of closes) {
                const f = findings.find((x) => x.id === id);
                if (!f || f.state !== 'open') fail('invalid', `closes: ${id} is not an open finding of ${fam.root.id}'s family`);
            }
            const own = landings.filter((l) => l.task_id === task.id);
            const id = `${task.id}#${own.length + 1}`;
            const previous = own.find((l) => l.superseded_by === null) ?? null;
            const updates = [touch('task', task, { state }), ...rootLock(task, fam)];
            if (previous) updates.push(touch('landing', previous, { superseded_by: id }));
            const fixed = [];
            for (const f of findings) {
                if (closes.includes(f.id)) { updates.push(touch('finding', f, { state: 'fixed', fixed_in: id })); fixed.push(f.id); }
                else if (previous && f.state === 'fixed' && f.fixed_in === previous.id) updates.push(touch('finding', f, { fixed_in: id }));
            }
            const row = {
                id, task_id: task.id, repo, commit, base_commit: base, commits, check_cmd: check.cmd, check_result: check.result,
                focus, closes, report_path: report, review_report_path: reviewReport, deployed: input.deployed ?? null, ...created(),
            };
            const states = { state_from: task.state, state_to: state };
            return {
                action: 'land', kind: 'landing', ref: id, states,
                changes: { creates: [{ kind: 'landing', row }], updates, log: [log('land', 'landing', id, { ...states, detail: { task: task.id, superseded: previous?.id ?? null } })] },
                notify: [...judgesOf(task), ...pms()],
                result: () => ({ task: { ...task, state }, landing: { ...row, superseded_by: null, version: 1 }, fixed, outside_commits: range.commits.filter((c) => !commits.includes(c)) }),
            };
        }),

        /** board-verdict: approve → done, changes → changes, hold → held. Opens findings, may reopen fixed ones. */
        verdict: (input = {}) => run(async () => {
            const landing = (await store.get('landing', text(input.landing, 'landing'))) ?? fail('not-found', `no landing ${input.landing}`);
            const task = await getTask(landing.task_id);
            if (landing.superseded_by) fail('stale-landing', `${landing.id} was superseded by ${landing.superseded_by}`);
            // the judge is never the assignee: add, assign and land refuse that pairing (§3.1)
            if (!judgesOf(task).includes(actor)) fail('forbidden', `${actor} does not judge ${task.id} (${judgesOf(task).join(', ')})`);
            const verdict = Object.hasOwn(VERDICTS, input.verdict) ? input.verdict : fail('invalid', `verdict must be ${Object.keys(VERDICTS).join(', ')}`);
            move('verdict', task);
            const state = VERDICTS[verdict];
            if (input.verified_commit !== landing.commit) fail('stale-landing', `${landing.id} is ${landing.commit}; verified_commit is ${input.verified_commit}`);
            const report = text(input.report, 'report');
            const rerun = { cmd: text(input.rerun?.cmd, 'rerun.cmd'), result: text(input.rerun?.result, 'rerun.result') };
            const raised = input.findings ?? [];
            if (!Array.isArray(raised)) fail('invalid', 'findings must be a list');
            const reopen = texts(input.reopen ?? [], 'reopen');

            const fam = await family(task);
            const famIds = fam.tasks.map((t) => t.id);
            const all = await store.list('verdict', {});
            const famLandings = new Set((await store.list('landing', { task_id: famIds })).map((l) => l.id));
            const famVerdicts = all.filter((v) => famLandings.has(v.landing_id)).map((v) => v.id);
            // the family's first verdict takes the next R<n>; later ones are R<n>a, R<n>b … (§2.8)
            const base = famVerdicts.length ? verdictBase(famVerdicts[0]) : null;
            const vid = base ? nextDerived(base, all.map((v) => v.id)) : nextNumbered('R', all.map((v) => v.id));

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
            const reopened = reopen.map((fid) => {
                const f = findings.find((x) => x.id === fid);
                if (!f || f.state !== 'fixed') fail('invalid', `reopen: ${fid} is not a fixed finding of ${fam.root.id}'s family`);
                return f;
            });
            if (verdict === 'approve') {
                const must = [...findings.filter((f) => f.state === 'open' || reopen.includes(f.id)), ...newFindings]
                    .filter((f) => f.severity === 'must').map((f) => f.id);
                if (must.length) fail('invalid', `cannot approve with open must findings in the family: ${must.join(', ')}`);
            }
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
                    ],
                    log: [log('verdict', 'verdict', vid, { ...states, detail: { landing: landing.id, verdict } })],
                },
                notify: [...pms(), task.assignee],
                result: () => ({ verdict: row, task: { ...task, state }, findings: newFindings.map((f) => f.id), reopened: reopen }),
            };
        }),

        /** board-finding: settle or reopen a finding (§3.2 FINDING_MOVES). */
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
                if (fam.tasks.every((t) => TERMINAL.includes(t.state))) {
                    fail('invalid', `${fam.root.id}'s family has no open task to fix ${f.id} in; ask pm for a derived task`);
                }
            }
            const patch = { state: to, ...(to === 'open' ? { fixed_in: null } : {}) };
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
            const updates = [touch('task', task, { state }), ...rootLock(task, fam)];
            const moved = [];
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
                changes: { updates, log: [log('cancel', 'task', task.id, { ...states, detail: { reason: input.reason ?? null } })] },
                notify: [task.assignee, ...(task.state === 'review' ? judgesOf(task) : [])],
                result: () => ({ task: { ...task, state }, findings: moved }),
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
