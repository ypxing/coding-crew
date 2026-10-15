#!/usr/bin/env bats

# scripts/cut-release.sh's demo-smoke gate (PRD D16/B8), always under --dry-run, in a throwaway
# repo with an upstream: no tag is made, nothing is pushed.

load helpers/smoke-demo

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  R="$BATS_TEST_TMPDIR/repo"
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git init -q -b main "$R"
  mkdir -p "$R/scripts" "$R/tests"
  cp "$REPO_ROOT/scripts/cut-release.sh" "$R/scripts/"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n\n- first\n' > "$R/CHANGELOG.md"
  echo '{"skills": {}}' > "$R/registry.json"
  git -C "$R" add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$R" remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git -C "$R" push -q -u origin main
  LOG="$BATS_TEST_TMPDIR/smoke.log"
}

release() { run bash "$R/scripts/cut-release.sh" --dry-run "$@"; }

@test "neither --demo-smoke nor --no-demo-smoke is refused, naming both" {
  release
  [ "$status" -ne 0 ]
  [[ "$output" == *"--demo-smoke"* ]]
  [[ "$output" == *"--no-demo-smoke"* ]]
  [[ "$output" != *"would tag"* ]]
}

@test "a log without SMOKE: PASS is refused" {
  printf 'SMOKE: FAIL: crew-afk exited 1\n' > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SMOKE: PASS"* ]]
  [[ "$output" != *"would tag"* ]]
}

@test "a passing log from a non-demo smoke run is refused" {
  printf 'SMOKE: PASS (claude)\n' > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *", demo)"* ]]
  [[ "$output" != *"would tag"* ]]
}

@test "a missing log is refused" {
  release --demo-smoke "$BATS_TEST_TMPDIR/nope.log"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope.log"* ]]
}

@test "a passing log at HEAD with a crew-afk-commit line and no crew-afk-version line is accepted" {
  printf 'SMOKE: repo ready\ncrew-afk-commit: %s\nSMOKE: PASS (claude, demo)\n' "$(git -C "$R" rev-parse HEAD)" > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}

passing_log_at() { printf 'crew-afk-commit: %s\nSMOKE: PASS (claude, demo)\n' "$1" > "$LOG"; }
commit_file() {
  mkdir -p "$R/$(dirname "$1")"; echo x >> "$R/$1"
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "$1"
}

@test "a passing log with no crew-afk commit is refused" {
  printf 'SMOKE: PASS (claude, demo)\n' > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"crew-afk-commit"* ]]
}

@test "a passing log from a dirty checkout is refused" {
  passing_log_at "$(git -C "$R" rev-parse HEAD)-dirty"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "a passing log at a commit with shipped changes after it is refused, naming them" {
  passing_log_at "$(git -C "$R" rev-parse HEAD)"
  commit_file skills/x/SKILL.md
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skills/x/SKILL.md"* ]]
}

@test "a passing log at a commit followed only by its RESULTS.md row and CHANGELOG.md is accepted" {
  passing_log_at "$(git -C "$R" rev-parse HEAD)"
  commit_file scripts/smoke-sprint/RESULTS.md
  commit_file CHANGELOG.md
  release --demo-smoke "$LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}

@test "a passing log at a commit HEAD does not descend from is refused" {
  passing_log_at 0123456789abcdef0123456789abcdef01234567
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not descend"* ]]
}

@test "--no-demo-smoke proceeds and prints the reason" {
  release --no-demo-smoke "demo repo not created yet"
  [ "$status" -eq 0 ]
  [[ "$output" == *"demo repo not created yet"* ]]
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}

@test "--no-demo-smoke needs a reason, and the two flags exclude each other" {
  release --no-demo-smoke ""
  [ "$status" -ne 0 ]
  printf 'SMOKE: PASS (claude)\n' > "$LOG"
  release --demo-smoke "$LOG" --no-demo-smoke why
  [ "$status" -ne 0 ]
}

@test "the log of a stubbed demo smoke run, its RESULTS.md row committed after it, is accepted" {
  # The smoke as cut-release meets it: run from this repo's own checkout, with install.sh stubbed to lay out
  # what a claude project install leaves, so crew-afk-commit: is this repo's HEAD.
  cp "$REPO_ROOT/scripts/smoke-sprint.sh" "$R/scripts/"
  cp "$REPO_ROOT/platforms.json" "$R/"
  printf '#!/usr/bin/env bash\nmkdir -p "$3/.claude/skills/crew-afk/scripts" "$3/.coding-crew/lib"\necho {} > "$3/.coding-crew/manifest.json"\n' > "$R/install.sh"
  chmod +x "$R/install.sh"
  mkdir -p "$R/scripts/smoke-sprint"
  printf '| commit | date | platform | result | cost | findings |\n|---|---|---|---|---|---|\n' > "$R/scripts/smoke-sprint/RESULTS.md"
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm smoke
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  make_smoke_demo
  "$R/scripts/smoke-sprint.sh" claude > "$LOG"
  grep -qx 'SMOKE: PASS (claude, demo)' "$LOG"
  commit_file scripts/smoke-sprint/RESULTS.md
  release --demo-smoke "$LOG"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}
