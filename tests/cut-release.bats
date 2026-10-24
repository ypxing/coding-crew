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
  pin_refs v1.0.0
  git -C "$R" add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$R" remote add origin "$BATS_TEST_TMPDIR/remote.git"
  git -C "$R" push -q -u origin main
  LOG="$BATS_TEST_TMPDIR/smoke.log"
}

release() { run bash "$R/scripts/cut-release.sh" --dry-run "$@"; }

# pin_refs <wf ref> [<caller ref>] — the reusable workflow's install step and the caller template's job at those refs.
pin_refs() {
  mkdir -p "$R/.github/workflows" "$R/skills/setup-coding-crew/hosts"
  printf 'jobs:\n  solve:\n    steps:\n      - uses: actions/checkout@v4\n      - name: Install\n        uses: ypxing/coding-crew/actions/install@%s\n        with:\n          agent: x\n' \
    "$1" > "$R/.github/workflows/crew-solve-feature.yml"
  printf '# `uses: ypxing/coding-crew/.github/workflows/crew-solve-feature.yml@vX.Y.Z` in prose is no ref.\njobs:\n  run:\n    uses: ypxing/coding-crew/.github/workflows/crew-solve-feature.yml@%s\n' \
    "${2:-$1}" > "$R/skills/setup-coding-crew/hosts/github-actions.yml"
}

@test "neither --demo-smoke nor --no-demo-smoke is refused, naming both and the smoke script" {
  release
  [ "$status" -ne 0 ]
  [[ "$output" == *"--demo-smoke"* ]]
  [[ "$output" == *"--no-demo-smoke"* ]]
  [[ "$output" == *"scripts/smoke-crew-afk.sh <platform>"* ]]
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
  [[ "$output" == *"scripts/smoke-crew-afk.sh <platform>"* ]]
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
  commit_file scripts/smoke-crew-afk/RESULTS.md
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
  cp "$REPO_ROOT/scripts/smoke-crew-afk.sh" "$R/scripts/"
  cp "$REPO_ROOT/platforms.json" "$R/"
  printf '#!/usr/bin/env bash\nmkdir -p "$3/.claude/skills/crew-afk/scripts" "$3/.coding-crew/lib"\necho {} > "$3/.coding-crew/manifest.json"\n' > "$R/install.sh"
  chmod +x "$R/install.sh"
  mkdir -p "$R/scripts/smoke-crew-afk"
  printf '| commit | date | platform | result | cost | findings |\n|---|---|---|---|---|---|\n' > "$R/scripts/smoke-crew-afk/RESULTS.md"
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm smoke
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  make_smoke_demo
  "$R/scripts/smoke-crew-afk.sh" claude > "$LOG"
  grep -qx 'SMOKE: PASS (claude, demo)' "$LOG"
  commit_file scripts/smoke-crew-afk/RESULTS.md
  release --demo-smoke "$LOG"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}

@test "a coding-crew uses: ref other than the release's tag, in either pinned file, is refused naming the file and the ref; both at the tag pass" {
  pin_refs v0.9.0 v1.0.0
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm old-wf
  release --no-demo-smoke "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *".github/workflows/crew-solve-feature.yml"*"@v0.9.0"*"@v1.0.0"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"would tag"* ]]
  pin_refs v1.0.0 main
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm old-caller
  release --no-demo-smoke "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/setup-coding-crew/hosts/github-actions.yml"*"@main"* ]] || { echo "$output"; return 1; }
  rm "$R/skills/setup-coding-crew/hosts/github-actions.yml"
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm no-caller
  release --no-demo-smoke "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/setup-coding-crew/hosts/github-actions.yml"* ]]
  pin_refs v1.0.0
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm bumped
  release --no-demo-smoke "x"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}

@test "a passing log at a commit followed only by the tag bump in the two pinned files is accepted" {
  pin_refs v0.9.0
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm old
  passing_log_at "$(git -C "$R" rev-parse HEAD)"
  pin_refs v1.0.0
  git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm bump
  release --demo-smoke "$LOG"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"would tag HEAD as v1.0.0"* ]]
}
