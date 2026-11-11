/**
 * The PreToolUse hook a worker with deny rules runs (T59): `--deny <rules> [--repo <root>]`, the tool call
 * as JSON on stdin. Exit 0 lets the call run; exit 2 refuses it, stderr going to the model, and the refusal
 * is one events.jsonl line. Input it cannot read is refused (hookCommand turns a crash into exit 2 too).
 */

import { appendEvent } from './lib/events.js';
import { bashDenial, pathDenial } from './lib/worker-guard.js';

function option(name) {
    const k = process.argv.indexOf(name);
    return k >= 0 ? process.argv[k + 1] : undefined;
}

async function stdin() {
    let text = '';
    for await (const chunk of process.stdin) text += chunk;
    return text;
}

const rules = (option('--deny') ?? '').split(',').filter(Boolean);
const repoRoot = option('--repo') ?? null;

let call;
try {
    call = JSON.parse(await stdin());
} catch {
    process.stderr.write('my-team guard: the tool call could not be read, so it is refused. 멈추고 pm(orchestrator)에 보고하라.\n');
    process.exit(2);
}

const { tool_name: tool, tool_input: input = {}, cwd = process.cwd() } = call;
let denial = null, target = null;
if (tool === 'Bash') {
    target = String(input.command ?? '');
    denial = bashDenial(target, rules);
} else if (['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].includes(tool) && rules.includes('repo-write')) {
    target = String(input.file_path ?? input.notebook_path ?? '');
    denial = pathDenial(target, cwd, repoRoot);
}

if (denial) {
    process.stderr.write(`my-team guard: this worker's "${denial.rule}" rule refuses it (${denial.reason}). `
        + '우회하지 말고 멈추고 pm(orchestrator)에 보고하라.\n');
    const stateRoot = process.env.MY_TEAM_STATE_ROOT;
    if (stateRoot) {
        const [team, worker] = (process.env.MY_TEAM_WORKER ?? '').split('/');
        await appendEvent(stateRoot, { type: 'tool-denied', team: team || null, worker: worker || null, tool, rule: denial.rule, target });
    }
    process.exit(2);
}
