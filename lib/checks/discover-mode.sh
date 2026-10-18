#!/usr/bin/env bash
# discover-mode.sh --project-root <path> — prints the prompt asking a model where this checkout's commands run
# (install_mode: docker or host, and docker_service), listing file paths, not contents. Prints "skipped" when the
# checkout has no compose file (host, nothing to decide) or its dev commands file (commands-file.sh) already
# records install_mode: a recorded mode, a hand edit included, is never re-asked.
# The prompt ends with the rule for confirming the answer and the commands that save it (write-commands-cache.sh),
# so every skill that decides the mode decides it the same way.

set -uo pipefail

PROJECT_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      PROJECT_ROOT="$2"
      shift 2
      ;;
    *) echo "discover-mode.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$PROJECT_ROOT" ] || [ ! -d "$PROJECT_ROOT" ]; then
  echo "Error: --project-root <existing dir> is required" >&2
  exit 2
fi

COMPOSE=""
for f in docker-compose.yml docker-compose.yaml compose.yml; do
  [ -f "$PROJECT_ROOT/$f" ] && { COMPOSE="$f"; break; }
done
if [ -z "$COMPOSE" ]; then
  echo "Mode discovery: skipped (no compose file: host)"
  exit 0
fi

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/commands-file.sh"
CACHE=$(commands_file "$PROJECT_ROOT")
if [ -n "$(commands_field "$CACHE" install_mode)" ]; then
  echo "Mode discovery: skipped (already recorded at $CACHE)"
  exit 0
fi

echo "Mode discovery: $COMPOSE and no install mode recorded — building the mode prompt"
echo
cat <<PROMPT
--- mode discovery prompt ---
This repository has $COMPOSE. Decide where a developer runs its dev-loop commands (install, test,
lint, typecheck) locally:

- docker — inside a compose service: the documented commands run in a container (a Makefile target
  whose recipe is \`docker compose run|exec <service> …\`, docs saying to run the tests in the container),
  or the toolchain the commands need exists only in a service's image.
- host — on the machine itself: compose only starts backing services (a database, LocalStack) that
  host-run tests connect to, or the docs run the commands directly.

For docker, also name the service the commands run in: the one the Makefile's recipes or the docs use,
else the one that builds or mounts this repository's source.

Read these files yourself, most authoritative first, and stop once you are confident:
PROMPT
for f in CLAUDE.md AGENTS.md Makefile README.md "$COMPOSE"; do
  [ -f "$PROJECT_ROOT/$f" ] && printf '  - %s\n' "$f"
done
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSWER="$PROJECT_ROOT/.discovered-mode.json"
cat <<PROMPT

On an interactive run, show the person your answer (the mode, the service, and the line that decided
it) and let them change it before you save it. On a non-interactive run (a headless/-p invocation or a
subagent), save it without asking.

Save it by running these commands with your answer as the JSON. Every worktree of this clone then reads
it from $CACHE.

cat > $(printf '%q' "$ANSWER") <<'JSON'
{"install_mode": "<docker or host>", "docker_service": "<service, or null for host>"}
JSON
(cd $(printf '%q' "$PROJECT_ROOT") && bash $(printf '%q' "$SELF_DIR/write-commands-cache.sh") --response-file .discovered-mode.json)
rm -f $(printf '%q' "$ANSWER")
--- end mode discovery prompt ---
PROMPT
