#!/usr/bin/env bash
# Usage: install.sh [--remove]
#
# Adds the prompt-refiner hook to ~/.claude/settings.json as a UserPromptSubmit
# command hook with a 90-second timeout. Keeps every other hook. Idempotent:
# a second run replaces the entry instead of adding a duplicate.
# --remove deletes the entry.
#
# Override the settings file with CLAUDE_SETTINGS=/path/to/settings.json.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT_DIR/hooks/user-prompt-submit.sh"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
STATE_DIR="${PROMPT_REFINER_STATE_DIR:-$HOME/.claude/prompt-refiner}"
TIMEOUT=90

command -v jq >/dev/null || { echo "install.sh: jq is required" >&2; exit 1; }
chmod +x "$HOOK" "$ROOT_DIR/scripts/"*.sh "$ROOT_DIR/tests/run.sh" 2>/dev/null || true

if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi
jq -e . "$SETTINGS" >/dev/null || { echo "install.sh: $SETTINGS is not valid JSON. Fix it first." >&2; exit 1; }

mkdir -p "$STATE_DIR/backups"
BACKUP="$STATE_DIR/backups/settings.json.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

# Drop any existing entry that points at this hook, then add a fresh one.
STRIP='.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | map(select(any(.hooks[]?; .command == $cmd) | not)))'

if [ "${1:-}" = "--remove" ]; then
  jq --arg cmd "$HOOK" "$STRIP"' | if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end' \
    "$SETTINGS" > "$SETTINGS.tmp"
  ACTION="removed from"
else
  jq --arg cmd "$HOOK" --argjson t "$TIMEOUT" "$STRIP"' + [{matcher: "", hooks: [{type: "command", command: $cmd, timeout: $t, statusMessage: "prompt-refiner"}]}]' \
    "$SETTINGS" > "$SETTINGS.tmp"
  ACTION="installed in"
fi

jq -e . "$SETTINGS.tmp" >/dev/null || { rm -f "$SETTINGS.tmp"; echo "install.sh: produced invalid JSON, settings untouched" >&2; exit 1; }
mv "$SETTINGS.tmp" "$SETTINGS"

echo "prompt-refiner hook $ACTION $SETTINGS"
echo "backup: $BACKUP"
echo "Restart Claude Code, or open /hooks once, so the change loads."
