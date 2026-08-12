### Model flag (--model is accepted but ignored on Copilot)

The `--model <alias|inherit>` flag is accepted for compatibility with the Claude platform interface.
On Copilot the model is chosen per session (`copilot --model`, `/model`, or the VS Code picker) and
subagents inherit it; `task` takes no model argument this skill can set per dispatch, and a persistent
per-agent override belongs in `~/.copilot/settings.json` under `subagents.agents.<name>.model`.

If `--model` is present, print an explicit notice:

```
Note: --model <value> was passed but is ignored on Copilot — the model is session-selected.
```

Set `RESOLVED_MODEL` to `"session-selected (--model ignored)"` for trace and summary output.

```bash
RESOLVED_MODEL="session-selected"
for arg in "$@"; do
  if [[ "$arg" == "--model" ]]; then
    _next_is_model=1
  elif [[ "${_next_is_model:-0}" == "1" ]]; then
    echo "Note: --model $arg was passed but is ignored on Copilot — the model is session-selected."
    RESOLVED_MODEL="session-selected (--model $arg ignored)"
    _next_is_model=0
  fi
done
```
