/**
 * The board's module boundaries (T63a, rfc/board-design.md §1): core imports only core; an adapter imports
 * only its own folder, core/contract.js and node: builtins; nothing but board/compose.js reaches an adapter.
 * The checker reads import specifiers from the source text (comments dropped, strings and regular expressions
 * masked), and is run on a fixture first so a rule that stops catching fails here instead of passing on a
 * clean tree. A mistake guard, not a sandbox: a load it cannot read (import() of anything but one string,
 * require, createRequire) is a failure anywhere under src (R66 R4).
 *
 * Known limits (R67a L1), accepted for a mistake guard: an import() inside a template literal's ${…} is masked
 * with the template and not seen; a regular expression right after `return`, `typeof` or `if (…)` is read as
 * division, so a quote inside it can hide an import later on the same line.
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
        return e.isDirectory() ? jsFiles(p) : /\.[cm]?js$/.test(e.name) ? [p] : [];
    });
}

/**
 * The text with comments turned to spaces and the inside of strings, template literals and regular
 * expressions turned to '_', at the same offsets, so patterns run on code only and a quoted specifier is read
 * back from the original. A '/' starts a regular expression after an operator, an opening bracket or nothing.
 */
function mask(text) {
    const out = [...text];
    let i = 0, prev = '';
    const blank = (from, to, ch) => { for (let k = from; k < to; k++) if (out[k] !== '\n') out[k] = ch; };
    while (i < text.length) {
        const c = text[i], d = text[i + 1];
        if (c === '/' && d === '/') { const e = text.indexOf('\n', i); const end = e < 0 ? text.length : e; blank(i, end, ' '); i = end; continue; }
        if (c === '/' && d === '*') { const e = text.indexOf('*/', i + 2); const end = e < 0 ? text.length : e + 2; blank(i, end, ' '); i = end; continue; }
        const regex = c === '/' && (prev === '' || /[(,=:[!&|?{};+\-*%<>~^]/.test(prev));
        if (c === "'" || c === '"' || c === '`' || regex) {
            let k = i + 1, inClass = false;
            while (k < text.length) {
                if (text[k] === '\\') { k += 2; continue; }
                if (regex && text[k] === '[') inClass = true;
                else if (regex && text[k] === ']') inClass = false;
                else if (text[k] === c && !inClass) break;
                else if (text[k] === '\n' && c !== '`') break;
                k++;
            }
            blank(i + 1, k, '_');
            i = k + 1; prev = 'x';
            continue;
        }
        if (!/\s/.test(c)) prev = c;
        i++;
    }
    return out.join('');
}

function specifiers(text) {
    const code = mask(text);
    const found = [];
    const quoted = (at) => text.slice(at + 1, code.indexOf(code[at], at + 1));
    for (const m of code.matchAll(/(?<![.\w$])(?:import|export)\s*(?:[\w*{$][^'"`;]*?(?<![\w$])from\s*)?(['"])/g)) {
        found.push(quoted(m.index + m[0].length - 1));
    }
    let unreadable = false;
    for (const m of code.matchAll(/(?<![.\w$])import\s*\(/g)) {
        const arg = /^\s*(['"])_*\1\s*\)/.exec(code.slice(m.index + m[0].length));
        if (arg) found.push(quoted(m.index + m[0].length + arg[0].indexOf(arg[1])));
        else unreadable = true;
    }
    if (/(?<![.\w$])(?:require|createRequire)\s*\(/.test(code)) unreadable = true;
    return { found, unreadable };
}

function targetOf(file, spec) {
    if (spec.startsWith('.')) return resolve(dirname(file), spec);
    if (spec.startsWith('/')) return resolve(spec);
    if (spec.startsWith('file:')) return fileURLToPath(spec);
    return null;
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
        const { found, unreadable } = specifiers(readFileSync(file, 'utf-8'));
        const inCore = inside(file, core);
        const adapter = inside(file, stores) ? join(stores, relative(stores, file).split(sep)[0]) : null;
        if (unreadable) out.push(`${rel}: a load whose target cannot be read (import() of a non-literal, require)`);
        for (const spec of found) {
            const target = targetOf(file, spec);
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
    put('board/core/fine.js', "/* import x from '../store/a.js' */\n// import y from 'fs';\nimport { KINDS } from './contract.js';\nconst a = 1 /* import z from 'fs' */;\n");
    put('board/store/memory/index.js', "import { KINDS } from '../../core/contract.js';\nimport { helper } from './helper.js';\nimport { DatabaseSync } from 'node:sqlite';\n");
    put('board/store/memory/helper.js', "export const helper = 1;\n");
    put('board/store/sqlite/index.js', "import { rules } from '../../core/service.js';\nimport { m } from '../memory/index.js';\nimport x from 'commander';\n");
    put('board/compose.js', "import { createMemoryStore } from './store/memory/index.js';\n");
    put('commands/api/board-add.js', "import { compose } from '../../board/compose.js';\nimport { s } from '../../board/store/sqlite/index.js';\n");
    put('commands/api/board-take.js', "export { s } from '../../board/store/sqlite/index.js';\n");
    put('lib/other.js', "const s = import('../board/store/sqlite/index.js');\n");
    // R66 R4: forms the first checker let through
    put('commands/api/board-tight.js', "import{m}from'../../board/store/memory/index.js'\n");
    put('board/core/tight.js', "import{m}from'../store/memory/index.js';\n");
    put('commands/api/board-tpl.js', "const m = await import(`../../board/store/memory/index.js`);\n");
    put('commands/api/board-var.js', "const p = '../../board/store/memory/index.js';\nconst m = await import(p);\n");
    put('commands/api/board-abs.js', `import { a } from '${join(root, 'board/store/memory/index.js')}';\nimport { b } from 'file://${join(root, 'board/store/memory/helper.js')}';\n`);
    put('lib/req.js', "import { createRequire } from 'module';\nconst load = createRequire(import.meta.url);\nload('../board/store/memory/index.js');\n");
    put('commands/api/board-ext.mjs', "import { m } from '../../board/store/memory/index.js';\n");
    put('board/core/str.js', "const open = '/*';\nimport x from '../store/memory/index.js';\nconst close = '*/';\n");
    // look like loads but are not
    put('lib/quiet.js', "const re = /['\"]\\/\\/ import('x')/;\nconst re2 = (/import(x)|require(y)/);\nconst msg = \"call import(x) or require(y)\";\nconst u = import.meta.url;\nconst t = `import('${u}')`;\nexport const n = 4 / 2 / 1;\n");

    assert.deepEqual(boundaryViolations(root).sort(), [
        "board/core/lazy.js: a load whose target cannot be read (import() of a non-literal, require)",
        "board/core/service.js: core imports ../store/memory/index.js",
        "board/core/service.js: core imports fs",
        "board/store/sqlite/index.js: adapter imports ../../core/service.js",
        "board/store/sqlite/index.js: adapter imports ../memory/index.js",
        "board/store/sqlite/index.js: adapter imports commander",
        "commands/api/board-add.js: reaches an adapter (../../board/store/sqlite/index.js); only board/compose.js may",
        "commands/api/board-take.js: reaches an adapter (../../board/store/sqlite/index.js); only board/compose.js may",
        "lib/other.js: reaches an adapter (../board/store/sqlite/index.js); only board/compose.js may",
        "commands/api/board-tight.js: reaches an adapter (../../board/store/memory/index.js); only board/compose.js may",
        "board/core/tight.js: core imports ../store/memory/index.js",
        "commands/api/board-tpl.js: a load whose target cannot be read (import() of a non-literal, require)",
        "commands/api/board-var.js: a load whose target cannot be read (import() of a non-literal, require)",
        `commands/api/board-abs.js: reaches an adapter (${join(root, 'board/store/memory/index.js')}); only board/compose.js may`,
        `commands/api/board-abs.js: reaches an adapter (file://${join(root, 'board/store/memory/helper.js')}); only board/compose.js may`,
        "lib/req.js: a load whose target cannot be read (import() of a non-literal, require)",
        "commands/api/board-ext.mjs: reaches an adapter (../../board/store/memory/index.js); only board/compose.js may",
        "board/core/str.js: core imports ../store/memory/index.js",
    ].sort());
});

test('src keeps the board boundaries', () => {
    assert.deepEqual(boundaryViolations(SRC), []);
});
