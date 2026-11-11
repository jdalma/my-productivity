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

/** A revision resolved to its full commit hash, or invalid. */
export function resolveCommit(repo, rev) {
    try {
        return git(repo, ['rev-parse', '--verify', '--quiet', `${rev}^{commit}`]);
    } catch {
        throw invalid(`no commit ${rev} in ${repo}`);
    }
}

/**
 * The commits sent when `commit` goes out, newest first (T63f): those after `upstream`, or, for a new
 * branch, those on no ref of `remote`.
 */
export function outgoingCommits(repo, { commit, upstream, remote }) {
    const tip = resolveCommit(repo, commit);
    let args;
    if (upstream) args = [`${resolveCommit(repo, upstream)}..${tip}`];
    else if (remote && /^[A-Za-z0-9._-]+$/.test(remote)) args = [tip, '--not', `--remotes=${remote}`];
    else throw invalid('give upstream (the remote\'s commit) or remote (its name, for a new branch)');
    return git(repo, ['rev-list', ...args]).split('\n').filter(Boolean);
}

/** Whether `commit` is `baseline` or one of its ancestors. */
export function withinBaseline(repo, commit, baseline) {
    try {
        git(repo, ['merge-base', '--is-ancestor', commit, baseline]);
        return true;
    } catch (err) {
        if (err.status === 1) return false;
        throw invalid(`git merge-base failed in ${repo}: ${String(err.stderr ?? err.message).trim()}`);
    }
}

export const subjectOf = (repo, commit) => git(repo, ['log', '-1', '--format=%s', commit]);
