/**
 * Config parser and validator for my-team.
 *
 * Schema (TeamConfig):
 *   { team_name, state_root?, new_window?, detached?, board?, workers: WorkerConfig[] }
 *
 * Implements AC-1, AC-19, AC-20, AC-24, AC-26, AC-27 from PLAN.md.
 */

import { readFileSync, existsSync, statSync } from 'fs';
import { isAbsolute, join, resolve, dirname } from 'path';
import { homedir } from 'os';

import { validateTeamName } from '../lib/team-name.js';
import { DENY_RULES } from '../lib/worker-guard.js';

const VALID_AGENT_TYPES = new Set(['claude', 'codex', 'gemini', 'cursor']);
const VALID_ROLES = new Set(['orchestrator', 'worker']);

/** Who and where a worker is: my-team sets them at launch, a config may not (T58). */
const IDENTITY_KEYS = new Set(['MY_TEAM_WORKER', 'OMC_TEAM_WORKER', 'MY_TEAM_STATE_ROOT']);

export const WORKER_NAME_PATTERN = /^[a-zA-Z0-9-]+$/;

function expandTilde(p) {
    if (!p) return p;
    if (p === '~') return homedir();
    if (p.startsWith('~/') || p.startsWith('~\\')) return join(homedir(), p.slice(2));
    return p;
}

/**
 * Auto-discover config file in callerCwd (AC-26).
 * Returns first match of: my-team.json, team.json. Null if neither exists.
 */
export function autoDiscoverConfig(callerCwd) {
    for (const name of ['my-team.json', 'team.json']) {
        const p = join(callerCwd, name);
        if (existsSync(p) && statSync(p).isFile()) return p;
    }
    return null;
}

/**
 * Load and validate a config file.
 * Returns normalized config object. Throws on validation failures.
 */
export function loadConfig(configPath) {
    if (!existsSync(configPath)) {
        throw new Error(`Config file not found: ${configPath}`);
    }
    let raw;
    try {
        raw = readFileSync(configPath, 'utf-8');
    } catch (err) {
        throw new Error(`Cannot read config file ${configPath}: ${err.message}`);
    }
    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (err) {
        throw new Error(`Config file is not valid JSON: ${err.message}`);
    }
    return validateConfig(parsed, { configPath });
}

function isAbsoluteOrTilde(p) {
    return typeof p === 'string' && (p === '~' || p.startsWith('~/') || p.startsWith('~\\') || isAbsolute(p));
}

/**
 * knowledge (optional, T68): the team's shared documents, [{path, about}], listed in every worker's AGENTS.md
 * by path and one line about each; the documents are not copied. A path is absolute or under ~.
 */
function knowledgeOf(knowledge) {
    if (knowledge === undefined) return null;
    const bad = (why) => { throw new Error(`knowledge ${why}. Expected [{"path": "/abs/doc.md", "about": "one line"}]. Got: ${JSON.stringify(knowledge)}`); };
    if (!Array.isArray(knowledge)) bad('must be a list');
    const items = knowledge.map((k, i) => {
        if (!k || typeof k !== 'object' || Array.isArray(k)) bad(`[${i}] must be an object`);
        const extra = Object.keys(k).filter((key) => key !== 'path' && key !== 'about');
        if (extra.length) bad(`[${i}] takes only path and about, not ${extra.join(', ')}`);
        if (!isAbsoluteOrTilde(k.path)) bad(`[${i}].path must be absolute or start with ~/`);
        if (typeof k.about !== 'string' || !k.about.trim() || /[\r\n]/.test(k.about)) bad(`[${i}].about must be one non-empty line`);
        return { path: expandTilde(k.path), about: k.about.trim() };
    });
    return items.length ? items : null;
}

/** The knowledge documents that are not there: start warns about them and goes on. */
export function missingKnowledge(knowledge) {
    return (knowledge ?? []).map((k) => k.path).filter((p) => !existsSync(p));
}

const BOARD_STORES = ['sqlite', 'memory'];

/**
 * board (optional, T63d): its presence makes the team a board team (docs/board.md, Turning it on). store picks the
 * adapter; memory keeps nothing between calls and is for tests.
 */
function boardOf(board) {
    if (board === undefined) return null;
    if (!board || typeof board !== 'object' || Array.isArray(board)) {
        throw new Error(`board must be an object like {"store": "sqlite"}. Got: ${JSON.stringify(board)}`);
    }
    const extra = Object.keys(board).filter((k) => k !== 'store');
    if (extra.length) throw new Error(`board takes only "store". Got: ${extra.join(', ')}`);
    const store = board.store ?? 'sqlite';
    if (!BOARD_STORES.includes(store)) throw new Error(`board.store must be ${BOARD_STORES.join('|')}. Got: ${JSON.stringify(store)}`);
    return { store };
}

/**
 * Validate + normalize an in-memory config object.
 * Returns a normalized config with expanded paths and defaults filled in.
 */
export function validateConfig(cfg, { configPath } = {}) {
    if (!cfg || typeof cfg !== 'object') {
        throw new Error('Config must be a JSON object');
    }

    const { team_name, state_root, new_window, detached, board, knowledge, workers } = cfg;

    if (typeof team_name !== 'string' || !team_name) {
        throw new Error('team_name is required (string)');
    }
    validateTeamName(team_name);

    // AC-24: state_root must be absolute or ~
    let resolvedStateRoot;
    if (state_root !== undefined) {
        if (typeof state_root !== 'string' || !isAbsoluteOrTilde(state_root)) {
            throw new Error(`state_root must be absolute or start with '~'. Got: ${JSON.stringify(state_root)}`);
        }
        resolvedStateRoot = expandTilde(state_root);
    } else {
        resolvedStateRoot = join(homedir(), '.my-team', 'sessions', team_name);
    }

    if (!Array.isArray(workers) || workers.length === 0) {
        throw new Error('workers must be a non-empty array');
    }
    if (workers.length > 10) {
        throw new Error(`workers cannot exceed 10. Got: ${workers.length}`);
    }

    const seen = new Set();
    const normalizedWorkers = workers.map((w, i) => validateWorker(w, i, seen));

    // Role mode is all-or-nothing per team: if ANY worker declares a role,
    // undeclared workers default to 'worker' and at least one orchestrator is
    // required (a role team with no initiator would deadlock — every worker
    // waiting for an orchestrator that does not exist). A config with no roles
    // at all stays in the legacy peer-symmetric mode.
    if (normalizedWorkers.some((w) => w.role !== null)) {
        for (const w of normalizedWorkers) {
            if (w.role === null) w.role = 'worker';
        }
        if (!normalizedWorkers.some((w) => w.role === 'orchestrator')) {
            throw new Error(
                "Config uses worker roles but has no 'orchestrator'. Mark at least one worker as role: 'orchestrator', or remove all role fields for peer-symmetric mode."
            );
        }
    }

    return {
        team_name,
        state_root: resolvedStateRoot,
        board: boardOf(board),
        knowledge: knowledgeOf(knowledge),
        new_window: Boolean(new_window),
        detached: Boolean(detached),
        workers: normalizedWorkers,
        _configPath: configPath ?? null,
    };
}

export function validateWorker(w, idx, seen) {
    const where = `workers[${idx}]`;
    if (!w || typeof w !== 'object') throw new Error(`${where} must be an object`);

    // AC-19: worker name pattern
    if (typeof w.name !== 'string' || !WORKER_NAME_PATTERN.test(w.name)) {
        throw new Error(`${where}.name must match /^[a-zA-Z0-9-]+$/. Got: ${JSON.stringify(w.name)}`);
    }
    if (seen.has(w.name)) {
        throw new Error(`Duplicate worker name: ${w.name}`);
    }
    seen.add(w.name);

    // AC-20: cwd absolute or ~
    if (typeof w.cwd !== 'string' || !isAbsoluteOrTilde(w.cwd)) {
        throw new Error(`${where}.cwd must be absolute or start with '~'. Got: ${JSON.stringify(w.cwd)}`);
    }
    const expandedCwd = expandTilde(w.cwd);
    if (!existsSync(expandedCwd)) {
        throw new Error(`${where}.cwd does not exist: ${expandedCwd}`);
    }
    if (!statSync(expandedCwd).isDirectory()) {
        throw new Error(`${where}.cwd is not a directory: ${expandedCwd}`);
    }

    // agent_type whitelist
    if (typeof w.agent_type !== 'string' || !VALID_AGENT_TYPES.has(w.agent_type)) {
        throw new Error(
            `${where}.agent_type must be one of ${[...VALID_AGENT_TYPES].join('|')}. Got: ${JSON.stringify(w.agent_type)}`
        );
    }

    // extra_prompt resolution (AC-27)
    let extraPrompt = '';
    if (typeof w.extra_prompt === 'string' && w.extra_prompt.trim()) {
        extraPrompt = w.extra_prompt;
        if (w.extra_prompt_file) {
            console.warn(
                `[my-team] worker '${w.name}': both extra_prompt and extra_prompt_file set, using inline (file ignored).`
            );
        }
    } else if (typeof w.extra_prompt_file === 'string' && w.extra_prompt_file) {
        const filePath = isAbsolute(w.extra_prompt_file)
            ? w.extra_prompt_file
            : expandTilde(w.extra_prompt_file);
        if (!existsSync(filePath)) {
            throw new Error(`${where}.extra_prompt_file does not exist: ${filePath}`);
        }
        extraPrompt = readFileSync(filePath, 'utf-8');
    }

    // description (optional): a one-line summary shown to *other* workers in
    // the Team Roster, so a worker LLM can judge whom to ask for help.
    // Distinct from extra_prompt (this worker's own detailed instructions).
    // A whitespace-only value normalizes to '' (same as extra_prompt above).
    let description = '';
    if (w.description !== undefined) {
        if (typeof w.description !== 'string') {
            throw new Error(`${where}.description must be a string`);
        }
        if (w.description.trim()) {
            description = w.description;
        }
    }

    // task field removed: my-team no longer tracks task lifecycle. The
    // initial work brief now lives in `extra_prompt` and is rendered into
    // the worker's AGENTS.md `## Role Context` section. Reject configs that
    // still carry the legacy field so users migrate explicitly.
    if (w.task !== undefined) {
        throw new Error(
            `${where}.task is no longer supported. Move your task subject/description into 'extra_prompt' (or 'extra_prompt_file'); my-team no longer tracks task lifecycle.`
        );
    }

    // role (optional): 'orchestrator' initiates/delegates and is the team's
    // cross-team gateway; 'worker' is reply-only (enforced in send-message).
    // Absent → null (legacy peer mode; validateConfig may default it to
    // 'worker' when the team declares roles elsewhere).
    let role = null;
    if (w.role !== undefined) {
        if (!VALID_ROLES.has(w.role)) {
            throw new Error(
                `${where}.role must be one of ${[...VALID_ROLES].join('|')}. Got: ${JSON.stringify(w.role)}`
            );
        }
        role = w.role;
    }

    // env (optional)
    let env = {};
    if (w.env !== undefined) {
        if (!w.env || typeof w.env !== 'object') {
            throw new Error(`${where}.env must be an object of string values`);
        }
        for (const [k, v] of Object.entries(w.env)) {
            if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) {
                throw new Error(`${where}.env: invalid key '${k}'`);
            }
            if (typeof v !== 'string') {
                throw new Error(`${where}.env.${k} must be a string`);
            }
            if (IDENTITY_KEYS.has(k)) {
                throw new Error(`${where}.env.${k} is set by my-team: it names the worker (send-message checks the sender against it)`);
            }
            env[k] = v;
        }
    }

    // launch_args (optional): extra CLI args appended to the worker binary
    // invocation. Useful for permission-bypass flags (e.g. claude
    // --dangerously-skip-permissions, codex --dangerously-bypass-approvals-
    // and-sandbox). User-owned: my-team does not interpret the flags, just
    // forwards them verbatim.
    let launchArgs = [];
    if (w.launch_args !== undefined) {
        if (!Array.isArray(w.launch_args)) {
            throw new Error(`${where}.launch_args must be an array of strings`);
        }
        for (const a of w.launch_args) {
            if (typeof a !== 'string') {
                throw new Error(`${where}.launch_args: each element must be a string, got ${typeof a}`);
            }
        }
        launchArgs = [...w.launch_args];
    }

    // deny (optional): rules a claude worker's PreToolUse hook keeps (T59, lib/worker-guard.js)
    let deny = [];
    if (w.deny !== undefined) {
        if (!Array.isArray(w.deny) || w.deny.some((r) => !DENY_RULES.includes(r))) {
            throw new Error(`${where}.deny must be an array of ${DENY_RULES.join('|')}. Got: ${JSON.stringify(w.deny)}`);
        }
        deny = DENY_RULES.filter((r) => w.deny.includes(r));
    }

    return {
        name: w.name,
        cwd: expandedCwd,
        agent_type: w.agent_type,
        role,
        description,
        extra_prompt: extraPrompt,
        env,
        launch_args: launchArgs,
        deny,
    };
}

/** Parse inline `--worker name:agent_type:cwd` spec into a WorkerConfig. */
export function parseInlineWorkerSpec(spec) {
    const parts = spec.split(':');
    if (parts.length < 3) {
        throw new Error(`Worker spec must be 'name:agent_type:cwd'. Got: ${spec}`);
    }
    const [name, agent_type, ...cwdParts] = parts;
    const cwd = cwdParts.join(':'); // rejoin in case cwd contains ':' (unlikely on posix)
    return { name, agent_type, cwd };
}
