#!/usr/bin/env bats

# solve-feature.sh with solveFeature.publish: false in the user-level config: the whole run stays on this machine,
# no push and no PR, the PR body kept in .coding-crew/solve-feature/local-pr-<branch>.md. Setup and the stubs:
# helpers/solve-feature.bash.

load helpers/solve-feature
bats_require_minimum_version 1.5.0

LOCAL=.coding-crew/solve-feature/local-pr-feature_feat.md
no_publish() { mkdir -p "$HOME/.coding-crew" && echo '{"solveFeature":{"publish":false}}' > "$HOME/.coding-crew/config.json"; }
# no_pr_calls — gh.log holds no PR call: every one would reach GitHub.
no_pr_calls() { ! grep -E '^(pr (create|view|edit|ready)|api graphql)' "$STATE/gh.log" 2>/dev/null || false; }
on_origin() { git ls-remote --exit-code origin "$1" >/dev/null; }
coder_notes() { printf '%s\n' "- tag a release once this merges" > .coding-crew/solve-feature/coder.notes.md; }

@test "a full run with publish false pushes nothing, calls no gh PR command and ends ready branch=<b> with the body in the local file" {
  no_publish
  # A coder's note lands in the local body's notes section as post_notes adds it to a PR body.
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out pr)" = "" ]
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2; coder_notes
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = pr=local ] || { echo "$output"; return 1; }
  [ ! -e .coding-crew/solve-feature/coder.notes.md ]
  [ "$(cat "$LOCAL")" = "$(cat <<EOF
# Feat

<!-- solve-feature:begin -->
Implemented by solve-feature (\`feat\`) — in progress.
<!-- solve-feature:notes:begin -->
## Notes for a person

Delete a note here once it is handled.

### the coder of 2 · $(date +%F)

- tag a release once this merges

<!-- solve-feature:notes:end -->
<!-- solve-feature:slug feat -->
<!-- solve-feature:end -->
EOF
)" ]
  run bash "$SCRIPT" next feat; [ "$output" = 3 ]
  coder 3
  run bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "reviewer-model=" ]
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '{"spec":"met","gaps":[],"findings":[{"severity":"LOW","location":"a:1","issue":"i","fix":"f"}]}\n' > .coding-crew/solve-feature/pr-local.review.json
  run bash "$SCRIPT" reviewed feat local feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = findings=1 ]
  echo fixed > fixed.txt
  printf '%s\n' "- rotate the key" > .coding-crew/solve-feature/pr-local.notes.md
  run bash "$SCRIPT" fix feat local feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=1 needs-attention=0 review-again=no" ]
  [ "$(git log -1 --format=%s)" = "Fix the review's findings" ]
  [ ! -e .coding-crew/solve-feature/pr-local.notes.md ]
  grep -qxF "### the fixer of feature/feat's review · $(date +%F)" "$LOCAL"
  # A person deletes the coder's note; describe keeps it deleted.
  perl -0pi -e 's/### the coder of 2[^\n]*\n\n- tag a release once this merges\n\n//' "$LOCAL"
  printf '# Let users log in\n\n## Why\n\nUsers need accounts.\n' > .coding-crew/solve-feature/pr-local.summary.md
  run bash "$SCRIPT" describe feat local
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "ready branch=feature/feat" ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "ready branch=feature/feat" ]
  [ "$(cat "$LOCAL")" = "$(cat <<EOF
# Let users log in

<!-- solve-feature:begin -->
> Written by solve-feature (\`feat\`): its coder, reviewer and fixer were agents; no person has read this body.

## Why

Users need accounts.

<!-- solve-feature:notes:begin -->
## Notes for a person

Delete a note here once it is handled.

### the fixer of feature/feat's review · $(date +%F)

- rotate the key

<!-- solve-feature:notes:end -->

Spec: PRD #1, feature \`feat\`

Closes #2
Closes #3
<!-- solve-feature:slug feat -->
<!-- solve-feature:end -->
EOF
)" ]
  ! on_origin feature/feat || false
  no_pr_calls
}

@test "publish false in the project's config.json alone has no effect: the run pushes and opens a draft PR" {
  echo '{"tracker":{"kind":"github"},"solveFeature":{"publish":false}}' > .coding-crew/config.json
  loop
  [ "$LAST_PR" = 10 ]
  on_origin feature/feat
  grep -q '^pr create --draft' "$STATE/gh.log"
  [ ! -e "$LOCAL" ]
}

@test "start prints pr=local only once this branch's local body exists, never deletes it, and ignores pr-body.md and another branch's file" {
  no_publish
  mkdir -p .coding-crew/solve-feature
  echo stale > .coding-crew/solve-feature/pr-body.md
  echo other > .coding-crew/solve-feature/local-pr-feature_other.md
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out pr)" = "" ]
  run bash "$SCRIPT" next feat; coder 2
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$output" = pr=local ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out pr)" = local ]
  [ -s "$LOCAL" ]
  no_pr_calls
}

@test "next with publish false: no ready issue and no local body stops nothing landed; with it, exit 3 printing reviewer-model=" {
  no_publish
  run bash "$SCRIPT" start feat
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  echo other > .coding-crew/solve-feature/pr-body.md
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [[ "$output" == *"nothing landed"* ]]
  printf '# T\n\nbody\n' > "$LOCAL"
  rm .coding-crew/solve-feature/outcome
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "reviewer-model=" ]
  no_pr_calls
}

@test "sync with publish false on a branch origin lacks merges the default branch, gating only a merge that moved HEAD" {
  no_publish
  loop
  [ "$LAST_PR" = local ]
  rm -f "$STATE/checks.log"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$STATE/checks.log" ]
  git checkout -q main && echo fix > fix.txt && git add fix.txt && git commit -q -m "main: fix" && git push -q origin main
  git checkout -q feature/feat
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git merge-base --is-ancestor origin/main HEAD
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
  ! on_origin feature/feat || false
}

@test "sync with publish false gates a re-run after its conflict was resolved, or after its checks failed and a fix was committed" {
  no_publish
  loop
  echo mine > shared.txt && git add shared.txt && git commit -q -m "branch's shared"
  git checkout -q main && echo "main's" > shared.txt && git add shared.txt && git commit -q -m "main: shared" && git push -q origin main
  git checkout -q feature/feat
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 4 ]
  # What the resolver subagent does; the re-run leaves HEAD where it is, yet the merge was never checked.
  echo both > shared.txt && git add shared.txt && git commit -q --no-edit
  rm -f "$STATE/checks.head"
  CHECKS_RC=1 run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 1 ]
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  [ "$(cat .coding-crew/solve-feature/review.base 2>/dev/null)" != "$(git rev-parse HEAD)" ]
  # The person's fix, then a re-run: gated again.
  echo fixed > fixed.txt && git add fixed.txt && git commit -q -m "fix the checks"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
  ! on_origin feature/feat || false
}

@test "sync with publish false gates a fix committed after its checks failed, when the re-run starts over with start" {
  no_publish
  loop
  git checkout -q main && echo "main's" > main.txt && git add main.txt && git commit -q -m "main: moves" && git push -q origin main
  git checkout -q feature/feat
  CHECKS_RC=1 run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 1 ]
  # The person's fix, then a whole /solve-feature re-run: start clears the last outcome, next finds nothing to do.
  echo fixed > fixed.txt && git add fixed.txt && git commit -q -m "fix the checks"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  rm -f "$STATE/checks.head"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$STATE/checks.head" 2>/dev/null)" = "$(git rev-parse HEAD)" ] || { echo "fix reached review unchecked"; return 1; }
}

@test "a checks failure at land with publish false reopens the issue and stops without saying the work was pushed" {
  no_publish
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  [[ "$output" != *push* ]] || { echo "$output"; return 1; }
  ! on_origin feature/feat || false
}

@test "land with publish false that cannot write the local body reopens the issue and says how to retry" {
  no_publish
  land_ready
  mkdir "$LOCAL.tmp"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: 2 pr failed: cannot write $WORK/$LOCAL; 2 is ready again with its work committed on feature/feat: fix the cause, then re-run" ]
  [ "$(node "$LIB/tracker/cli.mjs" next --feature-slug feat)" = 2 ]
  ! on_origin feature/feat || false
}

@test "describe with publish false keeps the notes of a local body a person saved with CRLF line endings" {
  no_publish
  land_ready
  coder_notes
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$output" = pr=local ] || { echo "$output"; return 1; }
  perl -pi -e 's/\n/\r\n/' "$LOCAL"
  : > .coding-crew/solve-feature/pr-local.attention.md
  printf '# Let users log in\n\n## Why\n\nUsers need accounts.\n' > .coding-crew/solve-feature/pr-local.summary.md
  run bash "$SCRIPT" describe feat local
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF -- "- tag a release once this merges" "$LOCAL"
  ! grep -q $'\r' "$LOCAL" || false
}

@test "land with publish false whose merge of a person-pushed origin branch conflicts says to merge by hand, not to re-run in a fresh clone" {
  no_publish
  land_ready
  # The person pushed an earlier head themselves; a bot's commit on it conflicts with the coder's.
  git push -q origin HEAD~1:refs/heads/feature/feat
  branch_moves work-2.txt "the bot's version" >/dev/null
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: 2 merge failed: merging origin/feature/feat into feature/feat conflicts in work-2.txt; 2 is ready again: merge it by hand in this checkout, commit, then re-run" ]
}

@test "fix with publish false compares with the head saved in review.base: a fixer that changed nothing is flagged, no gh pr view" {
  no_publish
  loop
  printf '{"spec":"met","gaps":[],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}\n' > .coding-crew/solve-feature/pr-local.review.json
  run bash "$SCRIPT" fix feat local feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=1 needs-attention=1 review-again=no" ]
  grep -qx "the fixer changed nothing" .coding-crew/solve-feature/pr-local.attention.md
  echo fixed > fixed.txt
  run bash "$SCRIPT" fix feat local feature/feat
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=1 needs-attention=0 review-again=yes" ]
  run bash "$SCRIPT" describe feat local
  [ "$output" = "ready branch=feature/feat" ]
  # write-pr wrote no summary: land's title stays.
  [ "$(head -n1 "$LOCAL")" = "# Feat" ] || { cat "$LOCAL"; return 1; }
  no_pr_calls
}

@test "SKILL.md documents solveFeature.publish as user-level only, pr=local, the branch= outcomes and write-pr on the branch" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -E '^\| `solveFeature.publish`.*user-level.*' "$skill" | grep -q push
  grep -q 'pr=local' "$skill"
  grep -q 'ready branch=<b>' "$skill"
  grep -q 'needs-attention branch=<b>' "$skill"
  grep -q 'write-pr skill on branch <branch>' "$skill"
}
