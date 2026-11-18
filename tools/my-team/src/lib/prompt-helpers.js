/**
 * Stub replacing oh-my-claude-sisyphus `dist/agents/prompt-helpers.js`.
 *
 * The original module wires agent role discovery, system-prompt resolution,
 * untrusted-content wrapping, etc. We only need `sanitizePromptContent` to
 * sanitize task subject/description embedded in worker AGENTS.md.
 */

export function sanitizePromptContent(content, maxLength = 4000) {
    if (!content) return '';
    let sanitized = content.length > maxLength ? content.slice(0, maxLength) : content;
    if (sanitized.length > 0) {
        const lastCode = sanitized.charCodeAt(sanitized.length - 1);
        if (lastCode >= 0xd800 && lastCode <= 0xdbff) {
            sanitized = sanitized.slice(0, -1);
        }
    }
    return sanitized.replace(
        /<(\/?)(system-instructions|system-reminder|TASK_SUBJECT|TASK_DESCRIPTION|INBOX_MESSAGE)(?=[\s>/])[^>]*>/gi,
        '[$1$2]'
    );
}
