### Model resolution

Parse the optional `--model <alias|inherit>` flag. `inherit` means "use whatever model this
orchestrator session runs on" — the dispatch script then passes no `--model` to the worker. Absent
the flag, workers run on pi's configured default. Any value must be a pattern the local `pi` CLI
resolves; check it with `pi --list-models <pattern>` before a long unattended run, because an
unresolvable pattern kills every dispatch instantly.

```bash
MODEL_FLAG=""
RESOLVED_MODEL="agent default"
for arg in "$@"; do
  if [[ "$arg" == "--model" ]]; then
    _next_is_model=1
  elif [[ "${_next_is_model:-0}" == "1" ]]; then
    MODEL_FLAG="--model $arg"
    RESOLVED_MODEL="$arg"
    _next_is_model=0
  fi
done

# A missing agent definition would fail every dispatch — check once, before round 1.
if [ ! -f "$MAIN_ROOT/.pi/agents/crew-coder.md" ] && [ ! -f "$HOME/.pi/agent/agents/crew-coder.md" ]; then
  echo "ERROR: crew-coder agent not installed. Run: ./install.sh pi --skill crew-afk"
  exit 1
fi
```
