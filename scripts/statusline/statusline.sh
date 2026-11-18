#!/usr/bin/env bash
#
# Claude Code status line.
#
# Reads the session JSON from stdin and prints a single line:
#
#   ~/IdeaProjects/my-claude-plugin  feat/cli-neutral ✱  Opus 4.8  $0.42
#
# Segments (each shown only when its data is present):
#   - cwd        : workspace.current_dir, with $HOME shortened to ~
#   - git        : current branch + ✱ when the working tree is dirty
#   - model      : model.display_name
#   - cost       : cost.total_cost_usd as $X.XX
#   - context    : context_window.used_percentage as N%
#
# This script must never fail in a way that blanks the status line, so it
# stays defensive: missing fields and failed git calls are silently skipped.
# Requires `jq`; without it, it falls back to printing just the cwd.

input="$(cat)"

# --- jq fallback ---------------------------------------------------------
# Without jq we cannot parse the JSON reliably. Print the best-effort cwd
# (grepped from the raw JSON) plus a hint, rather than an empty line.
if ! command -v jq >/dev/null 2>&1; then
  cwd="$(printf '%s' "$input" | grep -o '"current_dir":"[^"]*"' | head -1 | cut -d'"' -f4)"
  [ -n "$cwd" ] && cwd="${cwd/#$HOME/~}"
  printf '%s  (jq 필요)\n' "${cwd:-?}"
  exit 0
fi

# --- parse fields --------------------------------------------------------
cwd="$(printf '%s' "$input"   | jq -r '.workspace.current_dir // empty')"
model="$(printf '%s' "$input" | jq -r '.model.display_name // empty')"
cost="$(printf '%s' "$input"  | jq -r '.cost.total_cost_usd // empty')"
ctx="$(printf '%s' "$input"   | jq -r '.context_window.used_percentage // empty')"

# --- build segments ------------------------------------------------------
segments=()

# cwd: shorten $HOME to ~
if [ -n "$cwd" ]; then
  segments+=("${cwd/#$HOME/~}")
fi

# git: branch + dirty marker, only inside a work tree. All git calls are
# scoped to $cwd and any failure is swallowed so the line never breaks.
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$cwd" branch --show-current 2>/dev/null)"
  # Detached HEAD: fall back to short SHA.
  [ -z "$branch" ] && branch="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
  if [ -n "$branch" ]; then
    if [ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ]; then
      segments+=("$branch ✱")
    else
      segments+=("$branch")
    fi
  fi
fi

# model
[ -n "$model" ] && segments+=("$model")

# cost: format to two decimals; skip when zero/absent.
if [ -n "$cost" ] && [ "$cost" != "0" ]; then
  segments+=("$(printf '$%.2f' "$cost" 2>/dev/null || printf '$%s' "$cost")")
fi

# context: percentage of the context window used. Shown whenever the field is
# present (0% is meaningful — a fresh session), unlike cost.
[ -n "$ctx" ] && segments+=("${ctx}%")

# --- join with two spaces ------------------------------------------------
line=""
for seg in "${segments[@]}"; do
  if [ -z "$line" ]; then
    line="$seg"
  else
    line="$line  $seg"
  fi
done

printf '%s\n' "$line"
