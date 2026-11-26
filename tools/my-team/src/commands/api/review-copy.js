/**
 * `my-team api review-copy` (T51): the files of a submitted commit in a new temporary folder, for a reviewer's
 * rerun. One command for `mktemp -d`, `git archive <commit> | tar -x -C <folder>` and the dependency install: a
 * check never runs in a working tree a worker uses. The copy has no .git, and the result says so.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, normalize } from 'node:path';

import { BoardError } from '../../board/core/rules.js';
import { filesOf, resolveCommit, toplevel, unpackCommit } from '../../board/git.js';

const NOTE = 'A copy of the commit\'s files with no .git: a check that needs a git repository can fail here for that reason alone.';

export function runApiReviewCopy(input = {}) {
    if (typeof input.commit !== 'string' || !input.commit) throw new BoardError('invalid', 'commit is required');
    const repo = toplevel(input.repo ?? process.cwd());
    const commit = resolveCommit(repo, input.commit);
    // ponytail: npm only (a package-lock.json beside a package.json); add other installers when a repo needs one
    const installable = filesOf(repo, commit).filter((f) => f === 'package-lock.json' || f.endsWith('/package-lock.json'))
        .map((f) => dirname(f));
    const asked = input.install === true ? installable : (input.install || []);
    if (!Array.isArray(asked)) throw new BoardError('invalid', 'install is true or a list of folders of the copy');
    const folder = (dir) => (typeof dir === 'string' && !isAbsolute(dir) ? normalize(dir).replace(/\/+$/, '') : null);
    const wanted = asked.map(folder);
    for (const [i, dir] of wanted.entries()) {
        if (!installable.includes(dir)) {
            throw new BoardError('invalid', `install: ${asked[i]} has no package-lock.json in ${commit.slice(0, 7)} (it has: ${installable.join(', ') || 'none'})`);
        }
    }
    const path = mkdtempSync(join(tmpdir(), 'my-team-review-'));
    unpackCommit(repo, commit, path);
    for (const dir of wanted) {
        try {
            execFileSync('npm', ['ci', '--no-audit', '--no-fund'], { cwd: join(path, dir), stdio: ['ignore', 'pipe', 'pipe'] });
        } catch (err) {
            // npm writes the code and the cause first, then usage text and the log path (R48 L1)
            const cause = String(err.stderr ?? err.message).split('\n').filter((l) => l.trim() && l.trim() !== 'npm error').slice(0, 5);
            throw new BoardError('invalid', `npm ci failed in ${join(path, dir)}: ${cause.join('\n')}`);
        }
    }
    return { ok: true, path, commit, repo, git: existsSync(join(path, '.git')), note: NOTE, installable, installed: wanted };
}
