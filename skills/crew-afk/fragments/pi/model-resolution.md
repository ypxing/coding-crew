### Model resolution

Parse the optional `--model <alias|inherit>` flag. `inherit` means "use whatever model this
orchestrator session runs on" — the dispatch script then passes no `--model` to the worker. When the
flag is absent, the worker runs on pi's configured default model (the agent definitions pin no
model — see above). Any value passed here must be a pattern the local `pi` CLI resolves; check it
with `pi --list-models <pattern>` before a long unattended run, because an unresolvable pattern
kills every dispatch instantly.

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
if [ ! -f "$MAIN_ROOT/.pi/agents/crew-coder.md" ] && [ ! -f "$HOME/.pi/agent/agents/crew-coder.md" ]; then
  echo "ERROR: crew-coder agent not installed. Run: ./install.sh pi --skill crew-afk"
  exit 1
fi
```
