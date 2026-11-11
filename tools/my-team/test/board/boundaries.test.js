/**
 * The board's module boundaries (T63a, rfc/board-design.md §1): core imports only core; an adapter imports
 * only its own folder, core/contract.js and node: builtins; nothing but board/compose.js reaches an adapter.
 * The checker reads import specifiers from the source text, and is run on a fixture first so a rule that
 * stops catching fails here instead of passing on a clean tree.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { dirname, join, relative, resolve, sep } from 'path';
import { fileURLToPath } from 'url';

const SRC = fileURLToPath(new URL('../../src', import.meta.url));

function jsFiles(dir) {
    return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
        const p = join(dir, e.name);
        return e.isDirectory() ? jsFiles(p) : e.name.endsWith('.js') ? [p] : [];
    });
}

function specifiers(text) {
    const code = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    const found = [];
    for (const re of [
        /\b(?:import|export)\s[^'";]*?\bfrom\s*['"]([^'"]+)['"]/g,
        /\bimport\s*['"]([^'"]+)['"]/g,
        /\bimport\(\s*['"]([^'"]+)['"]\s*\)/g,
    ]) for (const m of code.matchAll(re)) found.push(m[1]);
    const dynamic = /\bimport\(\s*[^'"\s)]/.test(code);
    return { found, dynamic };
}

const inside = (path, dir) => path === dir || path.startsWith(dir + sep);

/** Every boundary break under srcRoot, as "<file>: <reason>". */
export function boundaryViolations(srcRoot) {
    const core = join(srcRoot, 'board', 'core');
    const stores = join(srcRoot, 'board', 'store');
    const contract = join(core, 'contract.js');
    const compose = join(srcRoot, 'board', 'compose.js');
    const out = [];
    for (const file of jsFiles(srcRoot)) {
        const rel = relative(srcRoot, file);
        const { found, dynamic } = specifiers(readFileSync(file, 'utf-8'));
        const inCore = inside(file, core);
        const adapter = inside(file, stores) ? join(stores, relative(stores, file).split(sep)[0]) : null;
        if ((inCore || adapter) && dynamic) out.push(`${rel}: an import() whose target cannot be read`);
        for (const spec of found) {
            const target = spec.startsWith('.') ? resolve(dirname(file), spec) : null;
            if (inCore) {
                if (!target || !inside(target, core)) out.push(`${rel}: core imports ${spec}`);
            } else if (adapter) {
                const ok = spec.startsWith('node:') || (target && (inside(target, adapter) || target === contract));
                if (!ok) out.push(`${rel}: adapter imports ${spec}`);
            } else if (file !== compose && target && inside(target, stores)) {
                out.push(`${rel}: reaches an adapter (${spec}); only board/compose.js may`);
            }
        }
    }
    return out;
}

test('the checker catches each kind of boundary break (fixture)', (t) => {
    const root = mkdtempSync(join(tmpdir(), 'mt-bounds-'));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const put = (path, text) => { mkdirSync(dirname(join(root, path)), { recursive: true }); writeFileSync(join(root, path), text); };
    put('board/core/contract.js', "export const KINDS = {};\n");
    put('board/core/service.js', "import { KINDS } from './contract.js';\nimport { x } from '../store/memory/index.js';\nimport fs from 'fs';\n");
    put('board/core/lazy.js', "const m = await import(name);\n");
    put('board/core/fine.js', "/* import x from '../store/a.js' */\n// import y from 'fs';\nimport { KINDS } from './contract.js';\n");
    put('board/store/memory/index.js', "import { KINDS } from '../../core/contract.js';\nimport { helper } from './helper.js';\nimport { DatabaseSync } from 'node:sqlite';\n");
    put('board/store/memory/helper.js', "export const helper = 1;\n");
    put('board/store/sqlite/index.js', "import { rules } from '../../core/service.js';\nimport { m } from '../memory/index.js';\nimport x from 'commander';\n");
    put('board/compose.js', "import { createMemoryStore } from './store/memory/index.js';\n");
    put('commands/api/board-add.js', "import { compose } from '../../board/compose.js';\nimport { s } from '../../board/store/sqlite/index.js';\n");
    put('commands/api/board-take.js', "export { s } from '../../board/store/sqlite/index.js';\n");
    put('lib/other.js', "const s = import('../board/store/sqlite/index.js');\n");

    assert.deepEqual(boundaryViolations(root).sort(), [
        "board/core/lazy.js: an import() whose target cannot be read",
        "board/core/service.js: core imports ../store/memory/index.js",
        "board/core/service.js: core imports fs",
        "board/store/sqlite/index.js: adapter imports ../../core/service.js",
        "board/store/sqlite/index.js: adapter imports ../memory/index.js",
        "board/store/sqlite/index.js: adapter imports commander",
        "commands/api/board-add.js: reaches an adapter (../../board/store/sqlite/index.js); only board/compose.js may",
        "commands/api/board-take.js: reaches an adapter (../../board/store/sqlite/index.js); only board/compose.js may",
        "lib/other.js: reaches an adapter (../board/store/sqlite/index.js); only board/compose.js may",
    ].sort());
});

test('src keeps the board boundaries', () => {
    assert.deepEqual(boundaryViolations(SRC), []);
});
