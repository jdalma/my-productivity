/**
 * Adapted from oh-my-claude-sisyphus (MIT License)
 * https://github.com/Yeachan-Heo/oh-my-claudecode
 *
 * Source: dist/team/fs-utils.js
 * Modifications: none (pristine copy).
 *
 * Shared filesystem utilities with permission hardening.
 * All file writes default to 0o600. All directory creates default to 0o700.
 */

import {
    writeFileSync, existsSync, mkdirSync, renameSync, openSync, writeSync, closeSync,
    realpathSync, constants,
} from 'fs';
import { dirname, resolve, relative, basename, join } from 'path';

export function atomicWriteJson(filePath, data, mode = 0o600) {
    const dir = dirname(filePath);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
    const tmpPath = `${filePath}.tmp.${process.pid}.${Date.now()}`;
    writeFileSync(tmpPath, JSON.stringify(data, null, 2) + '\n', { encoding: 'utf-8', mode });
    renameSync(tmpPath, filePath);
}

export function writeFileWithMode(filePath, data, mode = 0o600) {
    writeFileSync(filePath, data, { encoding: 'utf-8', mode });
}

export function appendFileWithMode(filePath, data, mode = 0o600) {
    const fd = openSync(
        filePath,
        constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT,
        mode
    );
    try {
        writeSync(fd, data, null, 'utf-8');
    } finally {
        closeSync(fd);
    }
}

export function ensureDirWithMode(dirPath, mode = 0o700) {
    if (!existsSync(dirPath)) mkdirSync(dirPath, { recursive: true, mode });
}

function safeRealpath(p) {
    try {
        return realpathSync(p);
    } catch {
        const segments = [];
        let current = resolve(p);
        while (!existsSync(current)) {
            segments.unshift(basename(current));
            const parent = dirname(current);
            if (parent === current) break;
            current = parent;
        }
        try {
            return join(realpathSync(current), ...segments);
        } catch {
            return resolve(p);
        }
    }
}

export function validateResolvedPath(resolvedPath, expectedBase) {
    const absResolved = safeRealpath(resolvedPath);
    const absBase = safeRealpath(expectedBase);
    const rel = relative(absBase, absResolved);
    if (rel.startsWith('..') || resolve(absBase, rel) !== absResolved) {
        throw new Error(`Path traversal detected: "${resolvedPath}" escapes base "${expectedBase}"`);
    }
}
