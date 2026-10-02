# Shared bats helper: drop the caller's PROJECT_ROOT/MAIN_ROOT so scripts under test resolve
# their roots from the scratch repo, not the shell that launched bats. Call from setup();
# a test that wants a value exports it afterwards and still gets it.
isolate_project_env() {
  unset PROJECT_ROOT MAIN_ROOT
}
