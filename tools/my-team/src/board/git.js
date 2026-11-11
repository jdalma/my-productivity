/**
 * The git port of the board (T63e; docs/board.md, Commands): land's checks in the assignee's
 * repository. Local reads only (cat-file, merge-base, rev-list, rev-parse); nothing touches a remote.
 * GIT_DIR and friends are dropped so `-C <repo>` is the repository asked, whatever the caller's environment.
 */

import { execFileSync } from 'node:child_process';

import { BoardError } from './core/rules.js';

const LOCATION_VARS = ['GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY'];

function git(repo, args) {
    const env = { ...process.env };
    for (const k of LOCATION_VARS) delete env[k];
    return execFileSync('git', ['-C', repo, ...args], { env, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

const invalid = (message) => new BoardError('invalid', message);

/** The top level of the repository `cwd` is in. */
export function toplevel(cwd) {
    try {
        return git(cwd, ['rev-parse', '--show-toplevel']);
    } catch {
        throw invalid(`${cwd} is not inside a git repository`);
    }
}

export const gitRange = {
    /** { ancestor, commits }: commits are base..commit, newest first (empty when base is no ancestor). */
    async range(repo, base, commit) {
        for (const c of [base, commit]) {
            try { git(repo, ['cat-file', '-e', `${c}^{commit}`]); } catch { throw invalid(`no commit ${c} in ${repo}`); }
        }
        try {
            git(repo, ['merge-base', '--is-ancestor', base, commit]);
        } catch (err) {
            if (err.status === 1) return { ancestor: false, commits: [] };
            throw invalid(`git merge-base failed in ${repo}: ${String(err.stderr ?? err.message).trim()}`);
        }
        return { ancestor: true, commits: git(repo, ['rev-list', `${base}..${commit}`]).split('\n').filter(Boolean) };
    },
};
