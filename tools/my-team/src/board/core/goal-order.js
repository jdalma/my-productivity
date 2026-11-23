/**
 * Goal order (T210; contract: docs/board.md, Goal order): the `## 순서` section of a goal file
 * turned into waves of start units, then matched against the board's tasks. Pure functions, no board access:
 * parseOrder reads the text, waves sorts the graph, annotate adds what the board says.
 */

const HEADING = '## 순서';
const REF = /^([A-Za-z]\w*)(?::(\d+)(?:-(\d+))?)?$/;
const MAX_ITEM = 1000; // a ticket's What list; a bigger range would only allocate (R6 L1)

/** `T177`, `T181:1` or `T177:4-7` -> { ref, task, items } (items null for the whole task), or a reason string. */
function parseRef(text) {
    const m = REF.exec(text);
    if (!m) return `bad reference "${text}"`;
    const [, task, lo, hi] = m;
    if (lo === undefined) return { ref: task, task, items: null };
    const a = Number(lo), b = hi === undefined ? a : Number(hi);
    if (a < 1 || b < a || b > MAX_ITEM) return `bad item range "${text}"`;
    return { ref: a === b ? `${task}:${a}` : `${task}:${a}-${b}`, task, items: Array.from({ length: b - a + 1 }, (_, i) => a + i) };
}

/**
 * The `## 순서` section as edges and listed refs. Every non-blank line there is `- before -> after`, each side a
 * comma list, or `- T1, T2`: tasks of the goal with no order among them (T222), listed again or not elsewhere.
 * Headings inside ``` fences do not count. A section that is missing gives found: false.
 * @returns {{ found: boolean, edges: { from: object, to: object, line: number }[], listed: object[], invalid: { line: number, text: string, reason: string }[] }}
 */
export function parseOrder(markdown) {
    const lines = markdown.split(/\r?\n/);
    const edges = [], listed = [], invalid = [];
    let found = false, inSection = false, fenced = false;
    lines.forEach((raw, i) => {
        const line = raw.trim();
        if (line.startsWith('```')) fenced = !fenced;
        if (!fenced && /^#{1,2}\s/.test(line)) {
            inSection = line === HEADING;
            found ||= inSection;
            return;
        }
        if (!inSection || line === '') return;
        const bad = (reason) => invalid.push({ line: i + 1, text: raw, reason });
        if (fenced || line.startsWith('```')) return bad('code block inside the order section');
        const m = /^[-*]\s+(.*)$/.exec(line);
        if (!m) return bad('expected "- before -> after" or "- T1, T2"');
        const sides = m[1].split('->');
        if (sides.length > 2) return bad('expected at most one "->"');
        const refs = sides.map((s) => s.split(',').map((t) => parseRef(t.trim())));
        const reason = refs.flat().find((r) => typeof r === 'string');
        if (reason) return bad(reason);
        if (refs.length === 1) return void listed.push(...refs[0]);
        const [from, to] = refs;
        for (const f of from) for (const t of to) edges.push({ from: f, to: t, line: i + 1 });
    });
    return { found, edges, listed, invalid };
}

/**
 * Start units and their waves (plan 2.2): one body node per task, one node per item range on the after side.
 * A range node also gets what its body gets. A whole task on the before side leaves from its body and every
 * range node; an item ref there leaves from the range nodes covering its items, and from its body for items no
 * range covers (D#9, so an item-level deadlock is a cycle). When a ref counts as complete is annotate's.
 * A listed ref (parseOrder's `listed`) is a node like an after-side ref, with no edge of its own (T222).
 * Kahn's algorithm: wave 1 is every node with nothing before it. A cycle gives cycle: [refs…, first ref] and no waves.
 * @returns {{ waves: { ref: string, task: string, items: number[]|null, after: object[] }[][], cycle: string[]|null }}
 */
export function waves(edges, listed = []) {
    const nodes = new Map();
    const node = (r) => {
        if (!nodes.has(r.ref)) nodes.set(r.ref, { ref: r.ref, task: r.task, items: r.items, after: new Map(), next: new Set() });
        return nodes.get(r.ref);
    };
    for (const { from, to } of edges) {
        node({ ref: from.task, task: from.task, items: null });
        node({ ref: to.task, task: to.task, items: null });
        if (to.items) node(to);
    }
    for (const r of listed) {
        node({ ref: r.task, task: r.task, items: null });
        if (r.items) node(r);
    }
    const all = [...nodes.values()];
    const rangesOf = (task) => all.filter((n) => n.task === task && n.items);
    // an item ref before leaves from the range nodes that cover its items, its body for items none covers (D#9)
    const itemSources = (r) => {
        const covering = rangesOf(r.task).filter((n) => n.items.some((i) => r.items.includes(i)));
        const uncovered = r.items.some((i) => !covering.some((n) => n.items.includes(i)));
        return uncovered ? [nodes.get(r.task), ...covering] : covering;
    };
    for (const { from, to } of edges) {
        const sources = from.items ? itemSources(from) : [nodes.get(from.task), ...rangesOf(from.task)];
        const targets = to.items ? [nodes.get(to.ref)] : [nodes.get(to.task), ...rangesOf(to.task)];
        for (const t of targets) {
            t.after.set(from.ref, from);
            for (const s of sources) s.next.add(t);
        }
    }

    const indegree = new Map(all.map((n) => [n, 0]));
    for (const n of all) for (const t of n.next) indegree.set(t, indegree.get(t) + 1);
    const out = [];
    let wave = all.filter((n) => indegree.get(n) === 0);
    let placed = 0;
    while (wave.length) {
        out.push(wave);
        placed += wave.length;
        const following = [];
        for (const n of wave) for (const t of n.next) if (indegree.set(t, indegree.get(t) - 1).get(t) === 0) following.push(t);
        wave = all.filter((n) => following.includes(n)); // first-seen order inside a wave
    }
    if (placed < all.length) return { waves: [], cycle: findCycle(all.filter((n) => indegree.get(n) > 0)) };
    return {
        waves: out.map((w) => w.map((n) => ({ ref: n.ref, task: n.task, items: n.items, after: [...n.after.values()] }))),
        cycle: null,
    };
}

/** One cycle among the nodes Kahn could not place (every one of them has a predecessor left among them). */
function findCycle(left) {
    const leftSet = new Set(left);
    const state = new Map(); // 1 on the path, 2 finished
    const path = [];
    const visit = (n) => {
        state.set(n, 1);
        path.push(n);
        for (const t of n.next) {
            if (!leftSet.has(t)) continue;
            if (state.get(t) === 1) return [...path.slice(path.indexOf(t)), t].map((x) => x.ref);
            if (!state.has(t)) {
                const found = visit(t);
                if (found) return found;
            }
        }
        path.pop();
        state.set(n, 2);
        return null;
    };
    for (const n of left) if (!state.has(n)) {
        const found = visit(n);
        if (found) return found;
    }
    return null;
}

/**
 * Board state on each node (plan 2.2, D4=1). `tasks` are board-status rows (id, title, state, progress_summary).
 * A whole-task before ref is complete when the task is done (approved); an item ref when its items are all in
 * done_items or the task is done. Anything else, cancelled and unregistered included, stays in blocked_by.
 * status: unregistered (not on the board), done, cancelled (the node's own task), ready_now, waiting.
 */
export function annotate(waveList, tasks) {
    const byId = new Map(tasks.map((t) => [t.id, t]));
    // a cancelled task completes nothing, whatever items it reported (plan 2.2: cancelled stays in blocked_by)
    const itemsDone = (task, items) => task?.state !== 'cancelled' &&
        (task?.state === 'done' || (!!items && items.every((i) => task?.progress_summary?.done_items?.includes(i))));
    const unregistered = new Set();
    const ready = [];
    const annotated = waveList.map((w) => w.map((n) => {
        const task = byId.get(n.task);
        const blocked = n.after
            .filter((r) => !itemsDone(byId.get(r.task), r.items))
            .map((r) => ({ ref: r.ref, state: byId.get(r.task)?.state ?? 'unregistered' }));
        let status;
        if (!task) status = 'unregistered';
        else if (itemsDone(task, n.items)) status = 'done';
        else if (task.state === 'cancelled') status = 'cancelled';
        else status = blocked.length ? 'waiting' : 'ready_now';
        if (!task) unregistered.add(n.task);
        if (status === 'ready_now') ready.push(n.ref);
        return { ...n, title: task?.title ?? null, state: task?.state ?? null, status, blocked_by: blocked };
    }));
    return { waves: annotated, ready_now: ready, unregistered: [...unregistered] };
}
