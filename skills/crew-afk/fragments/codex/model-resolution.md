### Model resolution

Parse the optional `--model <alias|inherit>` flag. `inherit` means "use whatever model this
orchestrator session runs on" — the dispatch script then passes no `--model` to the worker. When the
flag is absent, the model recorded in the agent definition (`.codex/agents/<name>.toml`) applies;
when that file pins no `model`, Codex resolves it from your own config.

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
```

Also confirm the worker agent is installed before round 1 — a missing definition means every
dispatch would fail:

```bash
if [ ! -f "$MAIN_ROOT/.codex/agents/crew-coder.toml" ] && [ ! -f "$HOME/.codex/agents/crew-coder.toml" ]; then
  echo "ERROR: crew-coder agent not installed. Run: ./install.sh codex --skill crew-afk"
  exit 1
fi
```
