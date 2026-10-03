#!/usr/bin/env bats
# The orchestrator-suite prefetch (tests/helpers/orchestrator-suite.bash): opt-in, and bounded by
# the bats run that started it. Runs a nested bats on a fixture repo whose "node --test" files
# record their pid and then sleep, so a leftover is visible.

setup() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  command -v bats >/dev/null 2>&1 || skip "bats not installed"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/tests/helpers" "$FIX/tests/orchestrator" "$FIX/pids"
  cp "$BATS_TEST_DIRNAME/helpers/orchestrator-suite.bash" "$FIX/tests/helpers/"
  local n
  for n in a b; do
    cat > "$FIX/tests/orchestrator/$n.test.mjs" <<JS
import { test } from "node:test";
import { writeFileSync } from "node:fs";
test("$n", async () => {
  writeFileSync("$FIX/pids/$n", String(process.pid));
  await new Promise((r) => setTimeout(r, Number(process.env.FIX_SLEEP_MS ?? 0)));
});
JS
    # printf, not a heredoc: bats rewrites an @test line anywhere in this file.
    printf 'load helpers/orchestrator-suite\n%s "%s" {\n  run_node_tests tests/orchestrator/%s.test.mjs\n}\n' "@test" "$n" "$n" > "$FIX/tests/orchestrator-$n.bats"
  done
  unset CI REPO_ROOT
}

# A nested bats starts from a clean env: none of this run's BATS_* state or exported functions.
nested() {
  # bats puts its libexec dir on PATH; the nested run must find the public `bats` instead.
  local path
  path=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'libexec' | paste -sd: -)
  local clean=(env -i "PATH=$path" "HOME=$HOME" "TMPDIR=${TMPDIR:-/tmp}")
  while [ "$1" = -u ]; do shift 2; done
  "${clean[@]}" "$@"
}

@test "prefetch: unset, one wrapper starts only its own node --test file" {
  cd "$FIX"
  run nested bats tests/orchestrator-a.bats

  [ "$status" -eq 0 ]
  [ -f "$FIX/pids/a" ]
  [ ! -f "$FIX/pids/b" ]
}

@test "prefetch: ORCHESTRATOR_PREFETCH=1 runs every wrapper's file and passes" {
  cd "$FIX"
  run nested ORCHESTRATOR_PREFETCH=1 bats tests/orchestrator-a.bats tests/orchestrator-b.bats
  [ "$status" -eq 0 ]
  [ -f "$FIX/pids/a" ] && [ -f "$FIX/pids/b" ]
}

@test "prefetch: an interrupted prefetching bats run leaves no node --test running" {
  cd "$FIX"
  nested ORCHESTRATOR_PREFETCH=1 FIX_SLEEP_MS=60000 bats tests/orchestrator-a.bats >/dev/null 2>&1 3>&- &
  local bp=$!
  local i=0
  while { [ ! -f "$FIX/pids/a" ] || [ ! -f "$FIX/pids/b" ]; } && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  [ -f "$FIX/pids/a" ] && [ -f "$FIX/pids/b" ]
  # SIGKILL the bats process tree at once (nothing gets to clean up: the worst case); the
  # prefetch's own node processes have to notice on their own.
  local all=("$bp") q
  for q in "${all[@]}"; do all+=($(pgrep -P "$q")); done
  for q in "${all[@]}"; do
    case "$(ps -o args= -p "$q" 2>/dev/null)" in *node*|*xargs*) ;; *) kill -9 "$q" 2>/dev/null || true ;; esac
  done
  for i in $(seq 1 60); do
    if ! kill -0 "$(cat "$FIX/pids/a")" 2>/dev/null && ! kill -0 "$(cat "$FIX/pids/b")" 2>/dev/null; then break; fi
    sleep 0.5
  done
  ! kill -0 "$(cat "$FIX/pids/a")" 2>/dev/null
  ! kill -0 "$(cat "$FIX/pids/b")" 2>/dev/null
}
