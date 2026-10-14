# setup_suite.bash — bats runs this once per `bats` invocation, before any test file.
setup_suite() {
  # No detached auto-maintenance in any scratch repo: git starts one after commit/merge, and one
  # still writing .git/objects (maintenance.lock, bitmap-ref-tips_*, pack/) when the git command
  # that started it returned made a teardown's rm -rf fail "Directory not empty" in CI. Command-scope
  # config, so it holds in tests that swap HOME, and appended to any GIT_CONFIG_COUNT list inherited.
  local n="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_$n=gc.auto" "GIT_CONFIG_VALUE_$n=0" \
    "GIT_CONFIG_KEY_$((n + 1))=maintenance.auto" "GIT_CONFIG_VALUE_$((n + 1))=false" \
    GIT_CONFIG_COUNT=$((n + 2))
}
