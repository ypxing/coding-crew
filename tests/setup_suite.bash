# setup_suite.bash — bats runs this once per `bats` invocation, before any test file.
#
# A crew-afk worker runs this suite with the live sprint's env inherited: MAIN_ROOT,
# CREW_ORCHESTRATED=1, and whatever sprint.env exported. Tests build their own sprints and
# must see neither the live one (their trace lines and markers would land in it) nor
# CREW_ORCHESTRATED (it switches off the sprint.env discovery several tests exercise), and
# a developer's own CREW_LOG_LEVEL/CREW_VERBOSE must not change what stderr assertions see.
setup_suite() {
  unset CREW_ORCHESTRATED MAIN_ROOT TRACE_LOG SPRINT_DIR STATE_FILE FEATURE_SLUG FEATURE_BRANCH \
    DISPATCH_DIR REVIEW_DIR CREW_SCRIPTS CREW_INSTALL_DIR CREW_FIX_FINDINGS \
    CREW_LOG_LEVEL CREW_VERBOSE

  # No detached auto-maintenance in any scratch repo: git starts one after commit/merge, and one
  # still writing .git/objects (maintenance.lock, bitmap-ref-tips_*, pack/) when the git command
  # that started it returned made a teardown's rm -rf fail "Directory not empty" five times in CI
  # (crew-afk-lease, crew-afk-scripts, eval-reviewer-misses, smoke-sprint). Command-scope config,
  # so it holds in tests that swap HOME, and appended to any GIT_CONFIG_COUNT list inherited.
  local n="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_$n=gc.auto" "GIT_CONFIG_VALUE_$n=0" \
    "GIT_CONFIG_KEY_$((n + 1))=maintenance.auto" "GIT_CONFIG_VALUE_$((n + 1))=false" \
    GIT_CONFIG_COUNT=$((n + 2))
}
