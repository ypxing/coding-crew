# setup_suite.bash — bats runs this once per `bats` invocation, before any test file.
#
# A crew-afk worker runs this suite with the live sprint's env inherited: MAIN_ROOT,
# CREW_ORCHESTRATED=1, and whatever sprint.env exported. Tests build their own sprints and
# must see neither the live one (their trace lines and markers would land in it) nor
# CREW_ORCHESTRATED (it switches off the sprint.env discovery several tests exercise).
setup_suite() {
  unset CREW_ORCHESTRATED MAIN_ROOT TRACE_LOG SPRINT_DIR STATE_FILE FEATURE_SLUG FEATURE_BRANCH \
    DISPATCH_DIR REVIEW_DIR CREW_SCRIPTS CREW_INSTALL_DIR CREW_PRD_AUDIT CREW_FIX_FINDINGS
}
