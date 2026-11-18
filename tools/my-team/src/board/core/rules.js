/**
 * Board rules as data (T63c; docs/board.md, States): states, who may do what, and how ids are made.
 * service.js reads these tables; a rule changes here, not in a branch of a command.
 */

export class BoardError extends Error {
    /** code: invalid, not-found, forbidden, invalid-transition, conflict, stale-landing */
    constructor(code, message) {
        super(message);
        this.name = 'BoardError';
        this.code = code;
    }
}

export const fail = (code, message) => { throw new BoardError(code, message); };

export const TERMINAL = ['done', 'cancelled'];
export const SEVERITIES = ['must', 'should', 'low'];
export const VERDICTS = { approve: 'done', changes: 'changes', hold: 'held' };
export const SETTLED = ['backlog', 'accepted-limit', 'rejected'];
/** The findings a landing may fix: backlog waits for a fix (T198); accepted-limit and rejected say there is none to make. */
export const FIXABLE = ['open', 'backlog'];
/** What a task hands in for review (T158): commits, or for a document task a report alone. A task row keeps `document` or null. */
export const DELIVERABLES = ['commits', 'document'];
export const isDocument = (task) => task.deliverable === 'document';

/**
 * Task transitions: command → the states it may start from and the state it leaves. `assign` has
 * three forms, told apart by its input (see service.assign).
 */
export const TASK_MOVES = {
    take: { from: ['ready', 'changes'], to: 'doing' },
    land: { from: ['doing'], to: 'review' },
    resubmit: { from: ['review'], to: 'review' },
    verdict: { from: ['review'], to: null },
    reassign: { from: ['new', 'ready', 'doing', 'changes', 'held'], to: 'ready' },
    rereview: { from: ['held'], to: 'review' },
    reviewer: { from: ['new', 'ready', 'doing', 'changes', 'review'], to: null },
    cancel: { from: ['new', 'ready', 'doing', 'review', 'changes', 'held', 'waiting'], to: 'cancelled' },
    // the user's decision (T115): in from any unfinished state, out to the state it came from
    wait: { from: ['new', 'ready', 'doing', 'changes', 'held', 'review'], to: 'waiting' },
    answer: { from: ['waiting'], to: null },
    // what the task says, corrected (T158): any unfinished state, which stays
    edit: { from: ['new', 'ready', 'doing', 'review', 'changes', 'held', 'waiting'], to: null },
    'decision-edit': { from: ['waiting'], to: null },
};

const WAITS_ON = { new: 'pm', ready: 'assignee', doing: 'assignee', changes: 'assignee', review: 'reviewer', held: 'pm' };
export const IN_HAND = Object.keys(WAITS_ON).filter((state) => WAITS_ON[state] === 'assignee');
const LOADED_FROM = 2;

/**
 * The line board-add and board-assign give pm when work piles up on `assignee`, or null. The board cannot tell
 * who is there to take tasks, so a worker counts as free only once it has been a task's assignee; one that has
 * been neither an assignee nor a task's reviewer, and is no pm, is named as possibly free.
 */
export function loadWarning(tasks, roster, assignee) {
    const inHand = (name) => tasks.filter((t) => t.assignee === name && IN_HAND.includes(t.state)).length;
    const n = inHand(assignee);
    if (n < LOADED_FROM) return null;
    const hasHadTask = (name) => tasks.some((t) => t.assignee === name);
    const others = roster.filter((w) => w.name !== assignee);
    const idle = others.map((w) => w.name).filter((name) => hasHadTask(name) && inHand(name) === 0);
    if (!idle.length) {
        const pms = pmsOf(roster);
        const unused = others.filter((w) => !pms.includes(w.name) && !hasHadTask(w.name) && !tasks.some((t) => t.reviewer === w.name)).map((w) => w.name);
        const where = unused.length
            ? `give it to ${unused.join(' or ')} (no task yet) if that worker is there to take tasks, or add a worker for it`
            : 'add a worker for it';
        return `${assignee} now has ${n} tasks in hand (ready, doing or changes) and no other worker who has taken a task is free: if this task can run in parallel with the work in hand, ${where}; if not, leave it queued`;
    }
    return `${assignee} now has ${n} tasks in hand (ready, doing or changes) while ${idle.join(', ')} ${idle.length > 1 ? 'have' : 'has'} none: split the task or give it to ${idle.length > 1 ? 'one of them' : idle[0]}`;
}

export function move(name, task) {
    const m = TASK_MOVES[name];
    if (!m.from.includes(task.state)) {
        fail('invalid-transition', `${task.id} is ${task.state}; ${name} needs ${m.from.join(' or ')}`);
    }
    return m.to ?? task.state;
}

/** Finding transitions through board-finding: [from states, to states, who]. */
export const FINDING_MOVES = [
    { from: ['open', 'fixed'], to: SETTLED, who: 'pm' },
    // a fix an approved landing made, recorded after the fact (T87): board-finding with `landing`
    { from: FIXABLE, to: ['fixed'], who: 'pm' },
    { from: SETTLED, to: ['open'], who: 'pm' },
    { from: ['fixed'], to: ['open'], who: 'reviewer' },
];

/**
 * The pm of a team: its orchestrators. A team that declares no roles is peer-symmetric, so every worker is
 * pm (the send-message rule for such teams).
 */
export function pmsOf(roster) {
    const declares = roster.some((w) => w.role === 'orchestrator' || w.role === 'worker');
    return roster.filter((w) => !declares || w.role === 'orchestrator').map((w) => w.name);
}

export const TASK_ID = /^[A-Za-z][A-Za-z0-9._-]{0,31}$/;
export const COMMIT = /^[0-9a-f]{40}$/;
export const FINDING_CODE = /^[A-Za-z0-9]{1,16}$/;

/** '' → a, a → b, z → aa, az → ba: the suffix after the one given (bijective base 26). */
export function nextLetters(s) {
    const chars = [...s];
    let i = chars.length - 1;
    while (i >= 0 && chars[i] === 'z') { chars[i] = 'a'; i--; }
    if (i < 0) return 'a' + chars.join('');
    chars[i] = String.fromCharCode(chars[i].charCodeAt(0) + 1);
    return chars.join('');
}

const lettersAfter = (id, base) => (id.startsWith(base) && /^[a-z]*$/.test(id.slice(base.length)) ? id.slice(base.length) : null);

/** Orders suffixes as nextLetters makes them: shorter first, then alphabetical. */
const bySuffix = (a, b) => a.length - b.length || (a < b ? -1 : a > b ? 1 : 0);

/** The next root id `<prefix><n>`, n one past the largest number in use. */
export function nextNumbered(prefix, ids) {
    const re = new RegExp(`^${prefix}(\\d+)[a-z]*$`);
    const top = ids.reduce((max, id) => Math.max(max, Number(re.exec(id)?.[1] ?? 0)), 0);
    return `${prefix}${top + 1}`;
}

/** The next derived id of `base`: base + the suffix after the largest one in use. */
export function nextDerived(base, ids) {
    const used = ids.map((id) => lettersAfter(id, base)).filter((x) => x !== null && x !== '').sort(bySuffix);
    return base + nextLetters(used.at(-1) ?? '');
}

/** R<n>[letters] split into its numbered base. */
export const verdictBase = (id) => /^R\d+/.exec(id)?.[0] ?? null;

/** The id the next verdict on a family takes: the next R<n> for its first, R<n>a, R<n>b … after. */
export function nextVerdictId(allIds, familyIds) {
    const base = familyIds.length ? verdictBase(familyIds[0]) : null;
    return base ? nextDerived(base, allIds) : nextNumbered('R', allIds);
}
