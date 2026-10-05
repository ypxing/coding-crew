#!/usr/bin/env bats

# scripts/cut-release.sh's demo-smoke gate (PRD D16/B8), always under --dry-run, in a throwaway
# repo with an upstream: no tag is made, nothing is pushed.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  R="$BATS_TEST_TMPDIR/repo"
  git init -q --bare "$BATS_TEST_TMPDIR/remote.git"
  git init -q -b main "$R"
  mkdir -p "$R/scripts" "$R/tests"
  cp "$REPO_ROOT/scripts/cut-release.sh" "$R/scripts/"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n\n- first\n' > "$R/CHANGELOG.md"
  echo '{"skills": {"crew-afk": {"version": "2.20.3"}}}' > "$R/registry.json"
  printf '#!/usr/bin/env bats\n@test ok { true; }\n' > "$R/tests/registry-version-bump.bats"
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
  printf 'crew-afk-version: 2.20.3\nSMOKE: FAIL: crew-afk exited 1\n' > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SMOKE: PASS"* ]]
  [[ "$output" != *"would tag"* ]]
}

@test "a passing log for another crew-afk version is refused" {
  printf 'crew-afk-version: 2.19.0\nSMOKE: PASS (claude, demo)\n' > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2.19.0"* ]]
  [[ "$output" == *"2.20.3"* ]]
}

@test "a passing log from a non-demo smoke run is refused" {
  printf 'crew-afk-version: 2.20.3\nSMOKE: PASS (claude)\n' > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--demo"* ]]
  [[ "$output" != *"would tag"* ]]
}

@test "a passing log with no crew-afk version is refused" {
  printf 'SMOKE: PASS (claude, demo)\n' > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"crew-afk-version"* ]]
}

@test "a missing log is refused" {
  release --demo-smoke "$BATS_TEST_TMPDIR/nope.log"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope.log"* ]]
}

@test "a passing log for HEAD's crew-afk version is accepted" {
  printf 'SMOKE: repo ready\ncrew-afk-version: 2.20.3\ncrew-afk-commit: %s\nSMOKE: PASS (claude, demo)\n' "$(git -C "$R" rev-parse HEAD)" > "$LOG"
  release --demo-smoke "$LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}

passing_log_at() { printf 'crew-afk-version: 2.20.3\ncrew-afk-commit: %s\nSMOKE: PASS (claude, demo)\n' "$1" > "$LOG"; }
commit_file() {
  mkdir -p "$R/$(dirname "$1")"; echo x >> "$R/$1"
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "$1"
}

@test "a passing log with no crew-afk commit is refused" {
  printf 'crew-afk-version: 2.20.3\nSMOKE: PASS (claude, demo)\n' > "$LOG"
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
  printf 'crew-afk-version: 2.20.3\nSMOKE: PASS (claude)\n' > "$LOG"
  release --demo-smoke "$LOG" --no-demo-smoke why
  [ "$status" -ne 0 ]
}
