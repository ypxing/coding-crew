### Model resolution

Parse the optional `--model <alias|inherit>` flag. `inherit` means "use whatever model this
orchestrator session runs on" — the dispatch script then passes no `--model` to the worker. Absent
the flag, the `model` in `.codex/agents/<name>.toml` applies, or your own config when it pins none.

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
if [ ! -f "$MAIN_ROOT/.codex/agents/crew-coder.toml" ] && [ ! -f "$HOME/.codex/agents/crew-coder.toml" ]; then
  echo "ERROR: crew-coder agent not installed. Run: ./install.sh codex --skill crew-afk"
  exit 1
fi
```
