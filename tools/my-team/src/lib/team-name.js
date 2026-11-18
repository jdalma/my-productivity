/**
 * Adapted from oh-my-claude-sisyphus (MIT License)
 * https://github.com/Yeachan-Heo/oh-my-claudecode
 *
 * Source: dist/team/team-name.js + sanitizeName extracted from dist/team/tmux-session.js
 * Modifications: sanitizeName co-located here so my-team modules can import a
 * single name-utility module without circular references through tmux-session.
 */

const TEAM_NAME_PATTERN = /^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$/;

export function validateTeamName(teamName) {
    if (!TEAM_NAME_PATTERN.test(teamName)) {
        throw new Error(
            `Invalid team name: "${teamName}". Team name must match /^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$/.`
        );
    }
    return teamName;
}

/**
 * Sanitize an arbitrary name (team or worker) to alphanumeric + hyphen.
 * Adapted from OMC `sanitizeName()` in tmux-session.js.
 */
export function sanitizeName(name) {
    const sanitized = String(name).replace(/[^a-zA-Z0-9-]/g, '');
    if (sanitized.length === 0) {
        throw new Error(`Invalid name: "${name}" contains no valid characters (alphanumeric or hyphen)`);
    }
    if (sanitized.length < 2) {
        throw new Error(`Invalid name: "${name}" too short after sanitization (minimum 2 characters)`);
    }
    return sanitized.slice(0, 50);
}
