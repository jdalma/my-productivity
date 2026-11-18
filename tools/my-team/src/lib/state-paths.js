/**
 * State path helpers for my-team's peer mailbox layout.
 *
 * Originally adapted from oh-my-claude-sisyphus (MIT License) but slimmed
 * down: after task lifecycle + inbox.md were removed (option-B cutover),
 * the only paths my-team writes are mailbox, archive, incoming-spool, and
 * a few per-worker liveness files. Anything else lives only as a comment
 * in this header.
 */

import { isAbsolute, join } from 'path';
import { homedir } from 'os';

function resolveTeamRoot(teamName) {
    const envRoot = process.env.MY_TEAM_STATE_ROOT?.trim();
    if (envRoot) return envRoot;
    const base = process.env.MY_TEAM_STATE_ROOT_BASE?.trim() || join(homedir(), '.my-team', 'sessions');
    return join(base, teamName);
}

function p(teamName, ...parts) {
    return [resolveTeamRoot(teamName), ...parts].join('/');
}

export const TeamPaths = {
    root: (teamName) => resolveTeamRoot(teamName),
    workers: (teamName) => p(teamName, 'workers'),
    workerDir: (teamName, workerName) => p(teamName, 'workers', workerName),
    overlay: (teamName, workerName) => p(teamName, 'workers', workerName, 'AGENTS.md'),
    ready: (teamName, workerName) => p(teamName, 'workers', workerName, '.ready'),
    workerStatus: (teamName, workerName) => p(teamName, 'workers', workerName, 'status.json'),
    mailbox: (teamName, workerName) => p(teamName, 'mailbox', `${workerName}.json`),
    archive: (teamName, workerName) => p(teamName, 'archive', `${workerName}.jsonl`),
    incomingSpoolDir: (teamName, workerName) => p(teamName, 'incoming-spool', workerName),
    incomingSpoolFile: (teamName, workerName, messageId) =>
        p(teamName, 'incoming-spool', workerName, `${messageId}.json`),
    manifest: (teamName) => p(teamName, 'manifest.json'),
};

export function absPath(cwd, relativePath) {
    return isAbsolute(relativePath) ? relativePath : join(cwd, relativePath);
}

export function teamStateRoot(cwd, teamName) {
    return absPath(cwd, TeamPaths.root(teamName));
}
