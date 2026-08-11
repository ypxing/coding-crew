### Model flag (--model is accepted but ignored on Copilot)

The `--model <alias|inherit>` flag is accepted for compatibility with the Claude platform interface.
On Copilot the model is IDE-selected and cannot be overridden programmatically — `#runSubagent` has
no model parameter. If `--model` is present, print an explicit notice:

```
Note: --model <value> was passed but is ignored on Copilot — the model is IDE-selected.
```

Set `RESOLVED_MODEL` to `"IDE-selected (--model ignored)"` for trace and summary output.

```bash
RESOLVED_MODEL="IDE-selected"
for arg in "$@"; do
  if [[ "$arg" == "--model" ]]; then
    _next_is_model=1
  elif [[ "${_next_is_model:-0}" == "1" ]]; then
    echo "Note: --model $arg was passed but is ignored on Copilot — the model is IDE-selected."
    RESOLVED_MODEL="IDE-selected (--model $arg ignored)"
    _next_is_model=0
  fi
done
```
