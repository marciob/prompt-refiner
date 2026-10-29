#!/usr/bin/env bash
# prompt-refiner: UserPromptSubmit hook for Claude Code.
#
# The hook reads the submitted prompt from stdin (JSON).
#   "++ <text>"   edit mode: refine, copy to the clipboard, block the prompt.
#   "++! <text>"  run mode:  refine, inject as additionalContext, let it run.
#   anything else no output, exit 0.
#
# The refiner is a separate headless Claude (claude -p). It reads the tail of
# the session transcript, not the main agent's context. The main agent adds
# no bias and gets no extra context. See ../README.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- configuration -----------------------------------------------------------
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/prompt-refiner/env"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

MODEL="${PROMPT_REFINER_MODEL:-sonnet}"
TIMEOUT="${PROMPT_REFINER_TIMEOUT:-75}"
MAX_CHARS="${PROMPT_REFINER_CONTEXT_CHARS:-12000}"
STATE_DIR="${PROMPT_REFINER_STATE_DIR:-$HOME/.claude/prompt-refiner}"
DRY_RUN="${PROMPT_REFINER_DRY_RUN:-0}"
NO_CLIPBOARD="${PROMPT_REFINER_NO_CLIPBOARD:-0}"
CLAUDE_BIN="${PROMPT_REFINER_CLAUDE_BIN:-}"
SYSTEM_FILE="${PROMPT_REFINER_SYSTEM_FILE:-$ROOT_DIR/prompts/refiner.md}"

# ---- helpers -----------------------------------------------------------------
json_block() {   # $1 = reason shown to the user
  jq -n --arg r "$1" '{
    decision: "block",
    reason: $r,
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", suppressOriginalPrompt: true }
  }'
}

json_context() { # $1 = text added to the model context
  jq -n --arg c "$1" '{
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $c }
  }'
}

copy_to_clipboard() {
  [ "$NO_CLIPBOARD" = "1" ] && return 0
  if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$1" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
  else return 1
  fi
}

resolve_claude() {
  local c
  if [ -n "$CLAUDE_BIN" ]; then
    [ -x "$CLAUDE_BIN" ] && { printf '%s' "$CLAUDE_BIN"; return 0; }
    return 1
  fi
  c="$(command -v claude 2>/dev/null || true)"
  if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  for c in "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.local/bin/claude"; do
    if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  c="$(ls -d "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | tail -n 1)"
  if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  return 1
}

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# ---- read the hook input -------------------------------------------------------
INPUT="$(cat)"
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"

case "$PROMPT" in
  '++!'*) MODE=run;  RAW="${PROMPT#++!}" ;;
  '++'*)  MODE=edit; RAW="${PROMPT#++}" ;;
  *)      exit 0 ;;
esac
RAW="$(trim "$RAW")"

if [ -z "$RAW" ]; then
  json_block "prompt-refiner: nothing after the ++ prefix."
  exit 0
fi

mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/last-run.log"
ERR="$STATE_DIR/last-error.log"
: > "$ERR"

TRANSCRIPT="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"

# ---- build the payload ---------------------------------------------------------
CONTEXT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  CONTEXT="$("$ROOT_DIR/scripts/extract-context.sh" "$TRANSCRIPT" "$MAX_CHARS" "$PROMPT" 2>>"$ERR" || true)"
fi
[ -n "$CONTEXT" ] || CONTEXT="(no session context available)"

PAYLOAD="$(printf 'Working directory: %s\n\n<session_context>\n%s\n</session_context>\n\n<raw_prompt>\n%s\n</raw_prompt>\n' "${CWD:-unknown}" "$CONTEXT" "$RAW")"
printf '%s' "$PAYLOAD" > "$STATE_DIR/last-payload.txt"

# ---- call the refiner ----------------------------------------------------------
START=$(date +%s)
REFINED=""
RC=0
if [ "$DRY_RUN" = "1" ]; then
  REFINED="[dry-run] $RAW"
else
  BIN="$(resolve_claude || true)"
  if [ -z "$BIN" ]; then
    RC=127; echo "claude binary not found" >>"$ERR"
  elif [ ! -f "$SYSTEM_FILE" ]; then
    RC=2; echo "system prompt not found: $SYSTEM_FILE" >>"$ERR"
  else
    SYSTEM="$(cat "$SYSTEM_FILE")"
    # cd to STATE_DIR so the headless agent does not load the project's CLAUDE.md.
    # perl alarm stops the call after $TIMEOUT seconds (macOS has no `timeout`).
    REFINED="$(cd "$STATE_DIR" && printf '%s' "$PAYLOAD" | perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT" \
      "$BIN" -p \
        --model "$MODEL" \
        --system-prompt "$SYSTEM" \
        --tools "" \
        --no-session-persistence \
        --setting-sources "" \
        --strict-mcp-config \
        --output-format text \
        2>>"$ERR")"
    RC=$?
  fi
fi
SECS=$(( $(date +%s) - START ))
REFINED="$(trim "$REFINED")"
printf '%s mode=%s model=%s rc=%s secs=%s chars_in=%s chars_out=%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$MODEL" "$RC" "$SECS" "${#PAYLOAD}" "${#REFINED}" >> "$LOG"

# ---- failure path --------------------------------------------------------------
if [ "$RC" -ne 0 ] || [ -z "$REFINED" ]; then
  DETAIL="$(head -c 300 "$ERR" | tr '\n' ' ')"
  [ "$RC" -eq 142 ] && DETAIL="timeout after ${TIMEOUT}s. $DETAIL"
  case "$MODE" in
    edit)
      copy_to_clipboard "$RAW" || true
      json_block "prompt-refiner failed (rc=$RC). $DETAIL
Your original prompt is in the clipboard. Cmd+V to paste it."
      ;;
    run)
      json_context "prompt-refiner: the ++! prefix asked for a refined prompt, but the refiner failed (rc=$RC). Treat the prompt as written, without the prefix."
      ;;
  esac
  exit 0
fi

# ---- success path --------------------------------------------------------------
printf '%s\n' "$REFINED" > "$STATE_DIR/last-prompt.txt"
case "$MODE" in
  edit)
    if copy_to_clipboard "$REFINED"; then
      HOWTO="Refined prompt is in the clipboard. Cmd+V to paste, edit, send."
    else
      HOWTO="No clipboard tool found. The refined prompt is in $STATE_DIR/last-prompt.txt."
    fi
    json_block "prompt-refiner (${SECS}s): $HOWTO

$REFINED"
    ;;
  run)
    json_context "prompt-refiner: the user wrote this prompt with the ++! prefix, which asks for a refined version to be executed in place of the literal text. Execute the refined prompt below as the user's request.

<refined_prompt>
$REFINED
</refined_prompt>"
    ;;
esac
exit 0
