# Hook install

`user-prompt-submit.sh` is a `UserPromptSubmit` command hook. Register it in `~/.claude/settings.json`.

Run `../scripts/install.sh`. It writes this entry and keeps the other hooks:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/prompt-refiner/hooks/user-prompt-submit.sh",
            "timeout": 90,
            "statusMessage": "prompt-refiner"
          }
        ]
      }
    ]
  }
}
```

Then restart Claude Code, or open `/hooks` once, so the hook loads.

The hook reads the prompt from stdin as JSON. For a prompt that starts with `++` or `++!`, it calls `claude -p` and writes a JSON decision to stdout. For every other prompt, it writes nothing and exits 0.
