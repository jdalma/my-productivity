#!/usr/bin/env bash
#
# Installs the Claude Code status line on this machine.
#
#   1. checks that `jq` is available
#   2. copies statusline.sh -> ~/.claude/statusline.sh (chmod +x)
#   3. backs up ~/.claude/settings.json
#   4. shows the change and asks for confirmation
#   5. merges only the `statusLine` key with jq (other keys untouched)
#
# Usage:
#   bash scripts/statusline/install.sh          # interactive
#   bash scripts/statusline/install.sh --yes     # no prompt (unattended setup)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/statusline.sh"
CLAUDE_DIR="$HOME/.claude"
DEST="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

ASSUME_YES=0
case "${1:-}" in
  --yes | -y) ASSUME_YES=1 ;;
esac

# --- 1. jq required ------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "✗ jq가 필요합니다. 먼저 설치하세요:" >&2
  echo "    macOS:  brew install jq" >&2
  echo "    Debian: sudo apt-get install jq" >&2
  exit 1
fi

if [ ! -f "$SRC" ]; then
  echo "✗ 원본 스크립트를 찾을 수 없습니다: $SRC" >&2
  exit 1
fi

# --- 2. copy the status line script -------------------------------------
mkdir -p "$CLAUDE_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "✓ 상태 라인 스크립트 설치: $DEST"

# The command run by Claude Code. ~ is expanded by the shell at render time.
STATUSLINE_CMD="bash ~/.claude/statusline.sh"
NEW_STATUSLINE="$(jq -n --arg cmd "$STATUSLINE_CMD" \
  '{type: "command", command: $cmd, padding: 0}')"

# --- 3 + 4. show change, confirm ----------------------------------------
echo ""
echo "settings.json에 주입할 statusLine:"
echo "$NEW_STATUSLINE" | sed 's/^/    /'
echo ""

if [ -f "$SETTINGS" ]; then
  CURRENT="$(jq -c '.statusLine // "없음"' "$SETTINGS" 2>/dev/null || echo '"(파싱 실패)"')"
  echo "현재 settings.json의 statusLine: $CURRENT"
else
  echo "현재 settings.json: 없음 (새로 생성됩니다)"
fi
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
  printf "settings.json을 위 내용으로 갱신할까요? [y/N] "
  read -r reply
  case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *) echo "중단했습니다. 스크립트 파일은 설치되었으나 settings.json은 그대로입니다." ; exit 0 ;;
  esac
fi

# --- 5. backup + merge statusLine key only ------------------------------
if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  echo "✓ 백업 생성: $BACKUP"
  TMP="$(mktemp)"
  jq --argjson sl "$NEW_STATUSLINE" '.statusLine = $sl' "$SETTINGS" > "$TMP"
  mv "$TMP" "$SETTINGS"
else
  jq -n --argjson sl "$NEW_STATUSLINE" '{statusLine: $sl}' > "$SETTINGS"
fi

echo "✓ settings.json 갱신 완료"
echo ""
echo "새 Claude Code 세션을 열면 상태 라인이 표시됩니다."
