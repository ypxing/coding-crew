#!/usr/bin/env bats

# scripts/smoke-sprint.sh — the fresh-repo, one-issue crew-afk sprint. Only --setup-only runs here
# (no platform CLI, no API cost): the fixture must install, pass its own tests, lint clean, and
# rebuild from scratch on a second run; a directory that is not a smoke repo is never deleted.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SMOKE="$REPO_ROOT/scripts/smoke-sprint.sh"
  D="$BATS_TEST_TMPDIR/smoke"
}

@test "setup-only builds a committed repo whose fixture tests pass and issues lint clean" {
  run "$SMOKE" claude --dir "$D" --setup-only
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$D" status --porcelain)" ]
  [ -f "$D/.coding-crew/crew-afk/main.mjs" ]
  (cd "$D" && node --test >/dev/null 2>&1)
  run bash "$D/.coding-crew/to-issues/scripts/lint-issues.sh" \
    --issue "$D/.scratch/subtract/issues/open/01-add-sub.md" \
    --deps "$D/.scratch/subtract/issues/issues-deps.json" --prd "$D/.scratch/subtract/PRD.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *WARN* ]]
}

@test "a second run rebuilds the repo from scratch" {
  "$SMOKE" claude --dir "$D" --setup-only
  git -C "$D" branch leftover
  echo stale > "$D/stale.txt"
  run "$SMOKE" claude --dir "$D" --setup-only
  [ "$status" -eq 0 ]
  [ ! -e "$D/stale.txt" ]
  ! git -C "$D" rev-parse -q --verify leftover
}

@test "an existing directory that is not a smoke repo is refused, not deleted" {
  mkdir -p "$D" && echo keep > "$D/keep.txt"
  run "$SMOKE" claude --dir "$D" --setup-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a smoke repo"* ]]
  [ -f "$D/keep.txt" ]
}

@test "an unknown platform is a usage error" {
  run "$SMOKE" nope --setup-only
  [ "$status" -eq 2 ]
}

# --demo: a pinned outside repo (here a local one through CREW_DEMO_REPO) and a demo dir
# (CREW_DEMO_DIR) laid out like scripts/smoke-sprint/demo/. The crew-afk call is a stub
# (CREW_SMOKE_AFK), so a "real" run costs nothing.

make_demo() {
  UP="$BATS_TEST_TMPDIR/upstream"
  git init -q -b main "$UP"
  echo one > "$UP/a.txt"
  git -C "$UP" add -A && git -C "$UP" -c user.email=t@t -c user.name=t commit -qm one
  PIN=$(git -C "$UP" rev-parse HEAD)
  echo two > "$UP/b.txt"
  git -C "$UP" add -A && git -C "$UP" -c user.email=t@t -c user.name=t commit -qm two
  DEMO="$BATS_TEST_TMPDIR/demo"
  mkdir -p "$DEMO/feature/issues/open"
  echo "$UP" > "$DEMO/repo"
  echo "$PIN" > "$DEMO/sha"
  printf '# the demo project checks\ntest -f a.txt\n\ntest -f ok.txt\n' > "$DEMO/check"
  echo "# PRD" > "$DEMO/feature/PRD.md"
  echo "# issue" > "$DEMO/feature/issues/open/01-one.md"
  STUB="$BATS_TEST_TMPDIR/afk-stub"
  cat > "$STUB" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$BATS_TEST_TMPDIR/afk-calls"
[[ "$1" == run ]] || exit 0
while [[ $# -gt 0 ]]; do [[ "$1" == --feature-slug ]] && slug="$2"; shift; done
mkdir -p ".scratch/$slug/issues/done" ".scratch/$slug/reviews"
mv ".scratch/$slug/issues/open/"*.md ".scratch/$slug/issues/done/"
echo '{"dispatches":[{"cost_usd":1.25,"duration_ms":3600000},{"cost_usd":0.25,"duration_ms":1800000}]}' > ".scratch/$slug/sprint-state.json"
printf '```json\n{"branch": "b1", "verdict": "met", "findings": [{"severity": "LOW", "location": "a.txt:1", "issue": "x"}]}\n```\n' > ".scratch/$slug/reviews/sprint-review-1.md"
git checkout -q -b "feature/$slug" && touch ok.txt && git add ok.txt && git commit -qm ok && git checkout -q main
SH
  chmod +x "$STUB"
  RESULTS="$BATS_TEST_TMPDIR/RESULTS.md"
  printf '| version | date | result | cost | dispatch-hours | findings |\n|---|---|---|---|---|---|\n' > "$RESULTS"
  export CREW_DEMO_DIR="$DEMO" CREW_SMOKE_AFK="$STUB" CREW_SMOKE_RESULTS="$RESULTS"
  VERSION=$(jq -r '.skills["crew-afk"].version' "$REPO_ROOT/registry.json")
}

@test "--demo --setup-only clones the pinned sha, places the feature and installs crew-afk without calling the CLI" {
  make_demo
  run env CREW_DEMO_REPO="$UP" "$SMOKE" claude --demo --dir "$D" --setup-only
  [ "$status" -eq 0 ]
  [ "$(git -C "$D" rev-list --max-parents=0 HEAD)" = "$PIN" ]
  [ ! -e "$D/b.txt" ]
  [ -f "$D/.scratch/demo/issues/open/01-one.md" ]
  [ -f "$D/.scratch/demo/PRD.md" ]
  [ -f "$D/.coding-crew/crew-afk/main.mjs" ]
  [ -z "$(git -C "$D" remote)" ]
  [[ "$output" == *"crew-afk-version: $VERSION"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/afk-calls" ]
  [ "$(wc -l < "$RESULTS")" -eq 2 ]
}

@test "--demo reads the slug from demo/slug when present" {
  make_demo
  echo calc > "$DEMO/slug"
  run "$SMOKE" claude --demo --dir "$D" --setup-only
  [ "$status" -eq 0 ]
  [ -f "$D/.scratch/calc/issues/open/01-one.md" ]
}

@test "--demo with a missing demo file exits 2 naming it" {
  make_demo
  for f in repo sha check feature; do
    mv "$DEMO/$f" "$DEMO/$f.gone"
    run "$SMOKE" claude --demo --dir "$D" --setup-only
    [ "$status" -eq 2 ]
    [[ "$output" == *"$DEMO/$f"* ]]
    mv "$DEMO/$f.gone" "$DEMO/$f"
  done
  rm "$DEMO/repo"
  run env CREW_DEMO_REPO="$UP" "$SMOKE" claude --demo --dir "$D" --setup-only
  [ "$status" -eq 0 ]
}

@test "a demo run passes when every issue is done and every check passes, and appends one results row" {
  make_demo
  run "$SMOKE" claude --demo --dir "$D"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SMOKE: PASS"* ]]
  [[ "$output" == *"crew-afk-version: $VERSION"* ]]
  [ "$(wc -l < "$RESULTS")" -eq 3 ]
  row=$(tail -n 1 "$RESULTS")
  [[ "$row" == "| $VERSION | "*" | PASS | \$1.50 | 1.50 | 1 |" ]]
}

@test "a demo run fails when a check command exits non-zero on the feature branch" {
  make_demo
  echo 'test -f missing.txt' >> "$DEMO/check"
  run "$SMOKE" claude --demo --dir "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: "*"test -f missing.txt"* ]]
  [[ "$output" == *"crew-afk-version: $VERSION"* ]]
  [ "$(wc -l < "$RESULTS")" -eq 3 ]
  [[ "$(tail -n 1 "$RESULTS")" == *"| FAIL |"* ]]
}

@test "a demo run fails when an issue is left open" {
  make_demo
  echo x > "$DEMO/feature/issues/open/02-left.md"
  sed -i.bak 's|^mv .*|mv ".scratch/$slug/issues/open/01-one.md" ".scratch/$slug/issues/done/"|' "$STUB"
  run "$SMOKE" claude --demo --dir "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: "*"02-left.md"* ]]
}

@test "the findings value folds the review reports one record per branch, latest wins" {
  make_demo
  cat >> "$STUB" <<'SH'
r=".scratch/demo/reviews"
printf '```json\n{"branch": "b1", "verdict": "unmet", "findings": [{"severity": "LOW", "location": "a.txt:1", "issue": "x"}, {"severity": "HIGH", "location": "b.txt", "issue": "y"}]}\n```\n' > "$r/sprint-review-1.md"
printf '```json\n{"branch": "b1", "verdict": "met", "findings": [{"severity": "LOW", "location": "a.txt:1", "issue": "x"}]}\n```\n' > "$r/sprint-review-2.md"
SH
  run "$SMOKE" claude --demo --dir "$D"
  [ "$status" -eq 0 ]
  [[ "$(tail -n 1 "$RESULTS")" == *"| PASS | "*" | 1 |" ]]
}

@test "a check that reads stdin does not swallow the later checks" {
  make_demo
  printf 'cat\ntest -f missing.txt\n' > "$DEMO/check"
  run "$SMOKE" claude --demo --dir "$D"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: "*"test -f missing.txt"* ]]
}

@test "a demo run whose checkout fails leaves a smoke repo the next run rebuilds without manual cleanup" {
  make_demo
  echo 0000000000000000000000000000000000000000 > "$DEMO/sha"
  run "$SMOKE" claude --demo --dir "$D" --setup-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot check out"* ]]
  echo "$PIN" > "$DEMO/sha"
  run "$SMOKE" claude --demo --dir "$D" --setup-only
  [ "$status" -eq 0 ]
  [ "$(git -C "$D" rev-list --max-parents=0 HEAD)" = "$PIN" ]
}

@test "--demo --dir <relative> records the sprint's real cost, dispatch-hours and findings" {
  make_demo
  cd "$BATS_TEST_TMPDIR"
  run "$SMOKE" claude --demo --dir smoke-rel
  [ "$status" -eq 0 ]
  [[ "$(tail -n 1 "$RESULTS")" == "| $VERSION | "*" | PASS | \$1.50 | 1.50 | 1 |" ]]
}
