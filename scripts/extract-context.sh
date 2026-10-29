#!/usr/bin/env bash
# Usage: extract-context.sh <transcript.jsonl> [max_chars] [current_prompt]
#
# Prints a compact view of the session transcript, one line per event:
#   USER: ...        what the developer typed
#   ASSISTANT: ...   what the agent said (first 800 chars)
#   TOOL: <name> <file|command|pattern|url>
#   RESULT: ...      first 300 chars of a tool result
# Drops thinking blocks, meta messages, subagent side chains, and consecutive
# duplicate lines. Drops the current prompt if it already reached the file.
# Keeps the last <max_chars> characters (default 12000).

set -uo pipefail
T="${1:-}"; MAX="${2:-12000}"; CUR="${3:-}"
[ -n "$T" ] && [ -f "$T" ] || exit 0

jq -r '
  select((.type == "user" or .type == "assistant") and (.isMeta != true) and (.isSidechain != true))
  | .type as $t
  | (.message.content // empty)
  | (if type == "string" then [{k: "USER", v: .}]
     elif type == "array" then map(
       if .type == "text" then {k: ($t | ascii_upcase), v: .text}
       elif .type == "tool_use" then {k: "TOOL", v: (.name + " " + ((.input.file_path // .input.command // .input.pattern // .input.url // .input.query // .input.description // "") | tostring))}
       elif .type == "tool_result" then {k: "RESULT", v: (.content | if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else "" end)}
       else empty end)
     else [] end)
  | .[]
  | select(.v != null and (.v | length) > 0)
  | .v |= gsub("[[:space:]]+"; " ")
  | (if .k == "USER" then .v |= .[0:1500]
     elif .k == "ASSISTANT" then .v |= .[0:800]
     elif .k == "RESULT" then .v |= .[0:300]
     else .v |= .[0:200] end)
  | "\(.k): \(.v)"
' "$T" 2>/dev/null \
| awk '$0 != prev { print } { prev = $0 }' \
| {
    if [ -n "$CUR" ]; then
      CURL="$(printf '%s' "$CUR" | tr -s '[:space:]' ' ')"
      grep -vxF -- "USER: $CURL" || true
    else
      cat
    fi
  } \
| tail -c "$MAX" \
| awk 'NR == 1 && $0 !~ /^(USER|ASSISTANT|TOOL|RESULT): / { next } { print }'
