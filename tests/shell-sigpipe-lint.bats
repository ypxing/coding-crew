#!/usr/bin/env bats

# `printf '%s\n' "$x" | grep -q …` under `set -o pipefail` fails at random: bash line-buffers
# printf, grep -q exits at its first matching line, and printf's next write gets SIGPIPE, which
# pipefail turns into a failed match. detect-service.sh lost its service this way in CI. A
# here-string (`grep -q … <<<"$x"`) has no pipe and no writer to kill.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

@test "no shipped shell script pipes printf/echo into grep -q" {
  run grep -rnE "(printf|echo)[^|]*\|[[:space:]]*grep -[a-zA-Z]*q" --include='*.sh' \
    "$REPO_ROOT/skills" "$REPO_ROOT/orchestrator" "$REPO_ROOT/tracker" "$REPO_ROOT/scripts" \
    "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}
