# setup_suite.bash — bats runs this once per `bats` invocation, before any test file.
#
# A crew-afk worker runs this suite with the live sprint's env inherited: MAIN_ROOT,
# CREW_ORCHESTRATED=1, and whatever sprint.env exported. Tests build their own sprints and
# must see neither the live one (their trace lines and markers would land in it) nor
# CREW_ORCHESTRATED (it switches off the sprint.env discovery several tests exercise), and
# a developer's own CREW_LOG_LEVEL/CREW_VERBOSE must not change what stderr assertions see.
setup_suite() {
  unset CREW_ORCHESTRATED MAIN_ROOT TRACE_LOG SPRINT_DIR STATE_FILE FEATURE_SLUG FEATURE_BRANCH \
    DISPATCH_DIR REVIEW_DIR CREW_SCRIPTS CREW_INSTALL_DIR CREW_PRD_AUDIT CREW_FIX_FINDINGS \
    CREW_LOG_LEVEL CREW_VERBOSE
  # The orchestrator node suites' prefetch (helpers/orchestrator-suite.bash) starts here, before
  # the first file, rather than at the first orchestrator-*.bats wrapper, which sorts late.
  if [ "${ORCHESTRATOR_PREFETCH:-}" = 1 ] && [ -z "${CI:-}" ] && command -v node >/dev/null 2>&1; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=helpers/orchestrator-suite.bash
    . "$REPO_ROOT/tests/helpers/orchestrator-suite.bash"
    orchestrator_prefetch_start
    unset REPO_ROOT
  fi
}
