/**
 * The SessionStart hook a claude worker runs after a context compaction (lib/protocol-reload.js):
 * `--file <AGENTS.md> --part <n>` prints part n of the worker's protocol, which Claude Code adds to the
 * context. A file it cannot read prints nothing: the worker goes on as it would have without the hook.
 */

import { readFileSync } from 'fs';

import { partText } from './lib/protocol-reload.js';

function option(name) {
    const k = process.argv.indexOf(name);
    return k >= 0 ? process.argv[k + 1] : undefined;
}

const file = option('--file');
let text = '';
try { text = readFileSync(file, 'utf-8'); } catch { /* nothing to print */ }
process.stdout.write(partText(file, text, Number(option('--part'))));
