/**
 * `tmux` as a worker finds it on PATH (T56): the real tmux for what tmuxShimVerdict allows, a refusal and an
 * events.jsonl line for the rest.
 */

import { spawnSync } from 'child_process';

import { appendEvent } from './lib/events.js';
import { findRealTmux, tmuxShimVerdict } from './lib/tmux-guard.js';

const args = process.argv.slice(2);

if (tmuxShimVerdict(args).allow) {
    const real = findRealTmux();
    if (!real) {
        process.stderr.write('[my-team] tmux shim: no tmux on PATH besides the shim\n');
        process.exit(127);
    }
    const r = spawnSync(real, args, { stdio: 'inherit' });
    if (r.error) {
        process.stderr.write(`[my-team] tmux shim: ${r.error.message}\n`);
        process.exit(127);
    }
    if (r.signal) process.kill(process.pid, r.signal);
    process.exit(r.status ?? 1);
}

process.stderr.write('사용자 tmux 서버에 대한 쓰기 명령은 거부됨. -L 또는 -S로 격리 서버를 지정\n');
const stateRoot = process.env.MY_TEAM_STATE_ROOT;
if (stateRoot) {
    const [team, worker] = (process.env.OMC_TEAM_WORKER ?? '').split('/');
    await appendEvent(stateRoot, { type: 'tmux-denied', team: team || null, worker: worker || null, args });
}
process.exit(1);
