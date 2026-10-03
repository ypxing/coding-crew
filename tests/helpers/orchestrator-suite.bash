# Shared by orchestrator.bats and the orchestrator-sprint-<topic>.bats wrappers: how the Node
# orchestrator's node:test files are found and run.

REPO_ROOT="${REPO_ROOT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"

# Every orchestrator test file except the sprint topic files, which run from their own bats
# wrappers so CI's shard split can put each on a different runner. A glob, not a list: a
# hand-kept list had silently dropped seven of the suite's files.
orchestrator_unit_tests() {
  local f
  for f in "$REPO_ROOT"/tests/orchestrator/*.test.mjs; do
    case "$(basename "$f")" in
      sprint-*.test.mjs) ;;
      *) printf '%s\n' "${f#"$REPO_ROOT"/}" ;;
    esac
  done
}

# run_node_tests <file>... — node --test from the repo root; the output only on failure.
run_node_tests() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  cd "$REPO_ROOT"
  if [ "$#" -eq 1 ] && [ -z "${CI:-}" ] && [ "${ORCHESTRATOR_PREFETCH:-1}" != 0 ] && [ -n "${BATS_RUN_TMPDIR:-}" ]; then
    _run_node_test_prefetched "$1"
    return
  fi
  run node --test "$@"
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
}

# Locally bats runs files one after another, and the single-file wrappers are 245 s of the run.
# The first wrapper to ask starts every wrapper's file at once in the background (node --test per
# file, xargs -P); each wrapper then waits for its own result. BATS_RUN_TMPDIR is shared by the
# whole bats invocation, so the cache dies with it. Off in CI (CI is set), where the shard split
# runs each wrapper in a process of its own, and with ORCHESTRATOR_PREFETCH=0.
_run_node_test_prefetched() {
  local file="$1" dir="$BATS_RUN_TMPDIR/orchestrator-prefetch" key
  key=$(printf '%s' "$file" | tr '/' '_')
  if mkdir "$dir" 2>/dev/null; then
    mkdir "$dir/out"
    local jobs
    jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    ( cd "$REPO_ROOT" && grep -h '^  run_node_tests ' tests/orchestrator-*.bats | awk '{print $2}' ) > "$dir/list.tmp" 2>/dev/null || true
    mv "$dir/list.tmp" "$dir/list"
    ( cd "$REPO_ROOT" && DIR="$dir" xargs -P "$jobs" -I{} bash -c         'k=$(printf %s "$1" | tr / _); node --test "$1" > "$DIR/out/$k.log" 2>&1; echo $? > "$DIR/out/$k.rc.tmp"; mv "$DIR/out/$k.rc.tmp" "$DIR/out/$k.rc"' _ {}         < "$dir/list"
      touch "$dir/done" ) >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
  fi
  # The prefetch list is written by whichever wrapper asked first; give it a moment to appear.
  local i=0
  while [ ! -f "$dir/list" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  # Bounded wait: a file the prefetch never started, or a prefetch job that ended without a
  # result for it, runs directly instead of waiting forever.
  if [ -f "$dir/list" ] && grep -qxF -- "$file" "$dir/list"; then
    while [ ! -f "$dir/out/$key.rc" ] && [ ! -f "$dir/done" ]; do sleep 0.5; done
  fi
  if [ ! -f "$dir/out/$key.rc" ]; then
    run node --test "$file"
    if [ "$status" -ne 0 ]; then
      echo "node --test $file failed (no prefetched result)" >&3
      echo "$output" >&3
    fi
    [ "$status" -eq 0 ]
    return
  fi
  status=$(cat "$dir/out/$key.rc")
  if [ "$status" -ne 0 ]; then
    cat "$dir/out/$key.log" >&3
  fi
  [ "$status" -eq 0 ]
}
