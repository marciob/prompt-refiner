# prompt-refiner

A Claude Code hook that rewrites a rough prompt into a precise one before the main agent sees it.

You type `++` and a rough prompt. A separate, fresh Claude reads the tail of your session and returns a refined prompt. The refined prompt goes to your clipboard. You paste it, edit it, and send it. The main agent never sees the rough prompt, the refiner, or the refiner's reasoning.

## Why a separate agent

The obvious design asks the main agent to improve the prompt. That design has two faults. The main agent carries the full session context, so its view is already shaped by that context. And the improvement itself adds tokens to that context.

This hook starts a new headless Claude for each refinement. The new Claude reads a compact extract of the session transcript, not the live context. It returns only the refined prompt. In edit mode, the main agent gets zero extra tokens. In run mode, it gets one short block.

## Two modes

| Prefix | Mode | What happens |
|---|---|---|
| `++ <prompt>` | edit | The hook blocks the prompt, copies the refined prompt to the clipboard, and shows it. Paste with Cmd+V, edit, send. |
| `++! <prompt>` | run | The hook lets the prompt through and tells the main agent to execute the refined version instead. |

Prompts without a prefix pass through untouched. For them, the hook exits in a few milliseconds.

## Install

1. Run `scripts/install.sh`. The script adds the hook to `~/.claude/settings.json` with a 90-second timeout. It keeps your other hooks.
2. Restart Claude Code, or open `/hooks` once, so the new hook loads.
3. Type `++ fix the failing test` and press Enter. After 5 to 20 seconds, a message shows the refined prompt.
4. Press Cmd+V. Edit the text. Press Enter.

To remove the hook, run `scripts/install.sh --remove`.

## Requirements

- Claude Code 2.1 or later, logged in. The refiner uses the same login as your session.
- `jq` and `perl`. Both are present on macOS.
- A clipboard tool: `pbcopy` on macOS, `wl-copy` or `xclip` on Linux. Without one, the hook saves the refined prompt to a file and names the file in the message.

## Configuration

Set these variables in the environment, or in `~/.config/prompt-refiner/env`.

| Variable | Default | Meaning |
|---|---|---|
| `PROMPT_REFINER_MODEL` | `sonnet` | Model for the refiner. |
| `PROMPT_REFINER_TIMEOUT` | `75` | Seconds before the hook stops the refiner. Keep it below the hook timeout of 90. |
| `PROMPT_REFINER_CONTEXT_CHARS` | `12000` | Size of the transcript extract sent to the refiner. |
| `PROMPT_REFINER_STATE_DIR` | `~/.claude/prompt-refiner` | Where the hook writes logs and the last prompt. |
| `PROMPT_REFINER_CLAUDE_BIN` | auto | Path to the `claude` binary, if the hook cannot find it. |
| `PROMPT_REFINER_SYSTEM_FILE` | `prompts/refiner.md` | The refiner's instructions. |
| `PROMPT_REFINER_DRY_RUN` | `0` | Set to `1` to skip the model call. For tests. |
| `PROMPT_REFINER_NO_CLIPBOARD` | `0` | Set to `1` to skip the clipboard. For tests. |

To change how prompts are refined, edit `prompts/refiner.md`. It is the one file to tune.

## Files

| Path | Role |
|---|---|
| `hooks/user-prompt-submit.sh` | The hook. Reads the prompt, calls the refiner, writes the hook output. |
| `scripts/extract-context.sh` | Turns the session transcript into a compact text extract. |
| `prompts/refiner.md` | The refiner's instructions. |
| `scripts/install.sh` | Adds or removes the hook in `~/.claude/settings.json`. |
| `tests/run.sh` | Offline tests. Add `--live` for one real model call. |

The hook writes these files in the state directory:

| File | Content |
|---|---|
| `last-prompt.txt` | The last refined prompt. Use it if the clipboard failed. |
| `last-payload.txt` | What the refiner received. Use it to debug a weak result. |
| `last-run.log` | One line per run: mode, model, exit code, seconds, sizes. |
| `last-error.log` | The stderr of the last run. |
| `backups/` | Copies of `settings.json` made by `install.sh`. |

## How the context extract works

Claude Code gives the hook the path of the session transcript. The extract script reads the transcript and keeps four kinds of lines. These are your messages, the agent's text, each tool call with its file or command, and the first 300 characters of each tool result. It drops thinking blocks, system messages, and subagent side chains. It keeps the last 12,000 characters.

Claude Code writes the transcript with a small delay. The last turn can be missing from the extract.

## Limits

- The hook cannot write into the input field. Claude Code hooks can add context or block a prompt. They cannot replace it. The clipboard is the bridge.
- A long refined prompt can appear as a collapsed `[Pasted text]` block after Cmd+V. The refiner writes one paragraph to reduce this. If it happens, send the text as is, or lower the length in `prompts/refiner.md`.
- The hook runs where Claude Code runs. In a cloud session, the clipboard is not on your machine.
- Each `++` costs one model call and 5 to 20 seconds.

## Test

Run `tests/run.sh` for the offline tests. Run `tests/run.sh --live` to add one real refinement with the fixture transcript.
