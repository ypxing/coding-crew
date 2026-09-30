# Shared by orchestrator.bats and the orchestrator-sprint-<k>.bats slice files: how the Node
# orchestrator's node:test files are found and run.

REPO_ROOT="${REPO_ROOT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"

# Every orchestrator test file except the sprint slices, which run from their own bats files
# so CI's shard split can put each on a different runner. A glob, not a list: a hand-kept
# list had silently dropped seven of the suite's files.
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
  run node --test "$@"
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
}
