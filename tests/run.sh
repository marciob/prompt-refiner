#!/usr/bin/env bash
# Tests for the prompt-refiner hook.
#   tests/run.sh          offline tests, no model call
#   tests/run.sh --live   adds one real refinement with the fixture transcript
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/user-prompt-submit.sh"
EXTRACT="$HERE/../scripts/extract-context.sh"
FIX="$HERE/fixtures/transcript.jsonl"
TMP="$(mktemp -d)"
export PROMPT_REFINER_STATE_DIR="$TMP/state"
export PROMPT_REFINER_NO_CLIPBOARD=1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }

run_hook() { # $1 = prompt text
  jq -n --arg p "$1" --arg t "$FIX" --arg c "$HERE" \
    '{hook_event_name: "UserPromptSubmit", prompt: $p, transcript_path: $t, cwd: $c, session_id: "test"}' \
  | "$HOOK"
}

# 1. No prefix: the hook stays silent.
out="$(run_hook "fix the test")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "no prefix: silent, exit 0"; else bad "no prefix" "rc=$rc out=$out"; fi

# 2. ++ edit mode (dry run): block JSON that carries the refined text.
out="$(PROMPT_REFINER_DRY_RUN=1 run_hook "++ fix the test")"
if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("[dry-run] fix the test")) and .hookSpecificOutput.suppressOriginalPrompt == true' >/dev/null 2>&1
then ok "++ edit mode: block + refined text"; else bad "++ edit mode" "$out"; fi

# 3. ++! run mode (dry run): additionalContext, no block.
out="$(PROMPT_REFINER_DRY_RUN=1 run_hook "++! fix the test")"
if printf '%s' "$out" | jq -e '(.decision == null) and (.hookSpecificOutput.additionalContext | contains("[dry-run] fix the test"))' >/dev/null 2>&1
then ok "++! run mode: additionalContext"; else bad "++! run mode" "$out"; fi

# 4. ++ with nothing after it: block with a message.
out="$(run_hook "++   ")"
if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("nothing after"))' >/dev/null 2>&1
then ok "++ empty: block"; else bad "++ empty" "$out"; fi

# 5. Refiner failure in edit mode: block, original prompt offered.
out="$(PROMPT_REFINER_SYSTEM_FILE=/nonexistent run_hook "++ fix the test")"
if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | contains("failed (rc=2)")) and (.reason | contains("original prompt"))' >/dev/null 2>&1
then ok "failure, edit mode: block + fallback message"; else bad "failure, edit mode" "$out"; fi

# 6. Refiner failure in run mode: prompt passes, context says to ignore the prefix.
out="$(PROMPT_REFINER_SYSTEM_FILE=/nonexistent run_hook "++! fix the test")"
if printf '%s' "$out" | jq -e '(.decision == null) and (.hookSpecificOutput.additionalContext | contains("failed"))' >/dev/null 2>&1
then ok "failure, run mode: pass-through context"; else bad "failure, run mode" "$out"; fi

# 7. Context extract: four line kinds present, noise absent.
ext="$("$EXTRACT" "$FIX" 12000)"
if printf '%s\n' "$ext" | grep -q '^USER: the login test' \
   && printf '%s\n' "$ext" | grep -q '^ASSISTANT: The cookie name' \
   && printf '%s\n' "$ext" | grep -q '^TOOL: Edit auth/session.py' \
   && printf '%s\n' "$ext" | grep -q '^TOOL: Bash pytest' \
   && printf '%s\n' "$ext" | grep -q '^RESULT: FAILED' \
   && ! printf '%s\n' "$ext" | grep -q 'must be dropped' \
   && ! printf '%s\n' "$ext" | grep -q 'hidden reasoning'
then ok "extract: USER/ASSISTANT/TOOL/RESULT kept, noise dropped"; else bad "extract" "$ext"; fi

# 8. Context extract drops the current prompt when it already reached the file.
ext="$("$EXTRACT" "$FIX" 12000 "++ arruma o teste que tá quebrando")"
if ! printf '%s\n' "$ext" | grep -q 'arruma o teste'; then ok "extract: current prompt dropped"; else bad "extract: current prompt" "$ext"; fi

# 9. Live refinement (opt-in).
if [ "${1:-}" = "--live" ]; then
  out="$(run_hook "++ arruma o teste que tá quebrando")"
  if printf '%s' "$out" | jq -e '.decision == "block" and (.reason | length > 60) and (.reason | contains("failed") | not)' >/dev/null 2>&1
  then
    ok "live: refined prompt returned"
    printf '\n--- refined ---\n%s\n---------------\n' "$(printf '%s' "$out" | jq -r '.reason' | sed '1,2d')"
    cat "$TMP/state/last-run.log"
  else
    bad "live" "$out
see $TMP/state/last-error.log"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
