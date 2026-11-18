/**
 * Stub replacing oh-my-claude-sisyphus `dist/utils/omc-cli-rendering.js`.
 *
 * The original module figures out whether to invoke OMC via `omc` binary
 * or `node "$CLAUDE_PLUGIN_ROOT"/bridge/cli.cjs`. my-team always renders
 * its own `my-team` prefix, so AGENTS.md generated through OMC's
 * `worker-bootstrap.js` automatically targets our CLI.
 */

const CLI_BINARY = 'my-team';

/**
 * Convert an OMC-style command suffix into a my-team invocation string.
 *
 * Input examples (with or without leading `omc`):
 *   `omc team api claim-task ...`
 *   `team api claim-task ...`
 *   `team status ...`
 *
 * Output rules:
 *   `team api <sub>` → `my-team api <sub>`
 *   `team <sub>`     → `my-team <sub>`
 *   `<other>`        → `my-team <other>`
 */
export function formatOmcCliInvocation(commandSuffix) {
    let suffix = String(commandSuffix).trim().replace(/^omc\s+/, '');
    suffix = suffix.replace(/^team\s+api\b/, 'api');
    suffix = suffix.replace(/^team\b\s*/, '');
    return `${CLI_BINARY}${suffix ? ' ' + suffix : ''}`.trim();
}
