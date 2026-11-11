#!/usr/bin/env bats

# solve-feature.sh's coder notes judged by the review: sync writes the body's coder blocks to pr-<n>.coder-notes.json,
# fix moves each one the report marks settled to the body's settled section, and describe keeps that section but
# never counts it. Setup and the stubs: helpers/solve-feature.bash.

load helpers/solve-feature

D=.coding-crew/solve-feature
NOTES=.coding-crew/solve-feature/pr-10.coder-notes.json
LOCAL=.coding-crew/solve-feature/local-pr-feature_feat.md

# coded_with_notes — #2's coder leaves a note with a ### heading of its own, #3's a plain one; both land, then sync.
coded_with_notes() {
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2
  printf '%s\n' '### Merge order' '' '- merge after the infra PR' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next feat; [ "$output" = 3 ]
  coder 3
  printf '%s\n' '- set the CREW_X repo variable' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 3 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = pr=10 ]
}
block2() { printf '%s\n\n%s\n\n%s' "### the coder of 2 · $(date +%F)" '### Merge order' '- merge after the infra PR'; }
block3() { printf '%s\n\n%s' "### the coder of 3 · $(date +%F)" '- set the CREW_X repo variable'; }
settled_section() { sed -n '/^<!-- solve-feature:settled:begin -->$/,/^<!-- solve-feature:settled:end -->$/p' "${1:-$STATE/pr-body}"; }
notes_section() { sed -n '/^<!-- solve-feature:notes:begin -->$/,/^<!-- solve-feature:notes:end -->$/p' "${1:-$STATE/pr-body}"; }

@test "sync writes the body's coder blocks, a coder's own ### heading kept inside its block, verbatim and in order, leaving out fixer and person blocks" {
  coded_with_notes
  # A fixer's block from an earlier run and a person's text are in the body too.
  perl -0pi -e 's/(Delete a note here once it is handled\.\n\n)/$1check the docs page\n\n/' "$STATE/pr-body"
  perl -0pi -e "s/(<!-- solve-feature:notes:end -->)/### the fixer of PR #10's review · 2026-01-01\n\n- rotate the key\n\n\$1/" "$STATE/pr-body"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c . "$NOTES")" = "$(jq -cn --arg a "$(block2)" --arg b "$(block3)" '[$a, $b]')" ] || { cat "$NOTES"; return 1; }
}

@test "sync with no coder block leaves no notes file, removing a stale one; a note a person deleted is not written" {
  coded_with_notes
  echo '["stale"]' > "$NOTES"
  perl -0pi -e 's/### the coder of [^\n]*\n\n(### Merge order\n\n)?- [^\n]*\n\n//g' "$STATE/pr-body"
  ! grep -q 'the coder of' "$STATE/pr-body" || false
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$NOTES" ]
}

@test "with publish false sync writes pr-local.coder-notes.json from the local body" {
  mkdir -p "$HOME/.coding-crew" && echo '{"solveFeature":{"publish":false}}' > "$HOME/.coding-crew/config.json"
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2
  printf '%s\n' '- set the CREW_X repo variable' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$output" = pr=local ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c . "$D/pr-local.coder-notes.json")" = "$(jq -cn --arg a "$(printf '%s\n\n%s' "### the coder of 2 · $(date +%F)" '- set the CREW_X repo variable')" '[$a]')" ]
}

@test "fix moves a settled note to the settled section with its why, keeps an unsettled one, and rewrites the notes file to what stands" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"both issues landed on this branch"},{"note":1,"settled":false,"why":"a repo variable only a person can set"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(settled_section)" = "$(printf '%s\n' '<!-- solve-feature:settled:begin -->' '## Settled by the review' '' "$(block2)" '' 'Settled by the review: both issues landed on this branch' '' '<!-- solve-feature:settled:end -->')" ] || { cat "$STATE/pr-body"; return 1; }
  ! notes_section | grep -q 'Merge order' || false
  notes_section | grep -qx -- '- set the CREW_X repo variable'
  [ "$(jq -c . "$NOTES")" = "$(jq -cn --arg b "$(block3)" '[$b]')" ]
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "needs-attention pr=10" ] || { echo "$output"; return 1; }
  [ "$(jq -c .needs_attention "$D/result.json")" = '[{"type":"note","author":"coder","text":"- set the CREW_X repo variable"}]' ]
  # Kept after the notes section, verbatim.
  [ "$(settled_section)" = "$(printf '%s\n' '<!-- solve-feature:settled:begin -->' '## Settled by the review' '' "$(block2)" '' 'Settled by the review: both issues landed on this branch' '' '<!-- solve-feature:settled:end -->')" ]
  [ "$(grep -n '^<!-- solve-feature:notes:end -->$' "$STATE/pr-body" | cut -d: -f1)" -lt "$(grep -n '^<!-- solve-feature:settled:begin -->$' "$STATE/pr-body" | cut -d: -f1)" ]

  # A second round judges only the note still standing, by its index in the rewritten file.
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"the variable is set by the workflow"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$NOTES" ]
  [ "$(grep -c '^Settled by the review: ' "$STATE/pr-body")" = 2 ]
  grep -qx 'Settled by the review: the variable is set by the workflow' "$STATE/pr-body"
  [ "$(grep -c '^<!-- solve-feature:settled:begin -->$' "$STATE/pr-body")" = 1 ]
}

@test "a run whose only notes were all settled ends ready, its settled section kept verbatim across describes" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"w0"},{"note":1,"settled":true,"why":"w1"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local section; section=$(settled_section)
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "ready pr=10" ] || { echo "$output"; cat "$STATE/pr-body"; return 1; }
  [ "$(jq -c .needs_attention "$D/result.json")" = '[]' ]
  ! grep -q '^## Needs attention$' "$STATE/pr-body" || false
  [ "$(settled_section)" = "$section" ]
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "ready pr=10" ]
  [ "$(settled_section)" = "$section" ]
}

@test "with publish false a run whose only note was settled ends ready branch=<b>" {
  mkdir -p "$HOME/.coding-crew" && echo '{"solveFeature":{"publish":false}}' > "$HOME/.coding-crew/config.json"
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2
  printf '%s\n' '- tag a release once this merges' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$output" = pr=local ]
  run bash "$SCRIPT" next feat; coder 3
  run bash "$SCRIPT" land feat 3 feature/feat
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"the release is cut by CI"}]}' > "$D/pr-local.review.json"
  run bash "$SCRIPT" fix feat local feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" describe feat local
  [ "$output" = "ready branch=feature/feat" ] || { echo "$output"; return 1; }
  grep -qx 'Settled by the review: the release is cut by CI' "$LOCAL"
}

@test "a coder note stands, and the run ends needs-attention, on a report with no notes key, no entry, an entry off its shape or out of range, settled false, or a block that no longer matches" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  cp "$STATE/pr-body" "$STATE/synced-body"; cp "$NOTES" "$STATE/synced-notes"
  local rep
  for rep in '' ',"notes":[]' ',"notes":"all settled"' ',"notes":[{"note":"0","settled":true,"why":"w"}]' \
    ',"notes":[{"note":5,"settled":true,"why":"w"}]' ',"notes":[{"note":-1,"settled":true,"why":"w"}]' \
    ',"notes":[{"note":0,"settled":"true","why":"w"}]' ',"notes":[{"note":0,"settled":true}]' \
    ',"notes":[{"note":0,"settled":false,"why":"w"}]' ',"notes":[{"note":0.5,"settled":true,"why":"w"}]' ',"notes":["0"]' edited; do
    cp "$STATE/synced-body" "$STATE/pr-body"; cp "$STATE/synced-notes" "$NOTES"
    if [ "$rep" = edited ]; then
      sed -i.bak 's/^- merge after the infra PR$/- merge after the infra PR lands/' "$STATE/pr-body"
      report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"w"}]}'
    else
      report "{\"spec\":\"met\",\"gaps\":[],\"findings\":[]$rep}"
    fi
    run bash "$SCRIPT" fix feat 10 feature/feat
    [ "$status" -eq 0 ] || { echo "$rep fix: $output"; return 1; }
    ! grep -q 'solve-feature:settled' "$STATE/pr-body" || { echo "$rep: settled"; return 1; }
    run bash "$SCRIPT" describe feat 10
    [ "$output" = "needs-attention pr=10" ] || { echo "$rep: $output"; return 1; }
    [ "$(jq -c '[.needs_attention[] | .author]' "$D/result.json")" = '["coder","coder"]' ] || { echo "$rep"; jq -c .needs_attention "$D/result.json"; return 1; }
  done
}

@test "a fix re-run after a stop moves each settled note once, with its own why" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"merged together"}]}'
  local before; before=$(cat "$NOTES")
  echo fixed > fixed.txt
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  ! grep -q 'solve-feature:settled' "$STATE/pr-body" || false
  [ "$(cat "$NOTES")" = "$before" ]
  refuse_pushes
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  ! grep -q 'solve-feature:settled' "$STATE/pr-body" || false
  rm "$TEMP_DIR/origin.git/hooks/pre-receive"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^Settled by the review: ' "$STATE/pr-body")" = 1 ]
  grep -qx 'Settled by the review: merged together' "$STATE/pr-body"
  [ "$(grep -c 'Merge order' "$STATE/pr-body")" = 1 ]
}

@test "a failed body write stops fix naming the recovery, moving nothing and keeping the notes file" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"w"}]}'
  local before; before=$(cat "$NOTES")
  GH_EDIT_FAIL=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"run fix feat 10 feature/feat, then describe feat 10"* ]] || { echo "$output"; return 1; }
  [ "$(cat "$NOTES")" = "$before" ]
  [ -f "$D/pr-10.review.json" ]
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^Settled by the review: w$' "$STATE/pr-body")" = 1 ]
}

@test "a note a person deleted before sync is neither judged nor brought back by fix or describe" {
  coded_with_notes
  perl -0pi -e 's/### the coder of 3[^\n]*\n\n- set the CREW_X repo variable\n\n//' "$STATE/pr-body"
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  [ "$(jq -c . "$NOTES")" = "$(jq -cn --arg a "$(block2)" '[$a]')" ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"w"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "ready pr=10" ] || { echo "$output"; return 1; }
  ! grep -q 'CREW_X' "$STATE/pr-body" || false
}

@test "SKILL.md names pr-<n>.coder-notes.json as the reviewer's notes input only when that file exists" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'When `<repo>/.coding-crew/solve-feature/pr-<n>.coder-notes.json` exists, `; the notes the change'"'"'s author left for a person are in <repo>/.coding-crew/solve-feature/pr-<n>.coder-notes.json` is appended last' "$skill"
}

@test "SKILL.md's reviewer prompt clauses append in order, so empty red files do not drop the notes clause" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'when that is empty, the `; the tests named…` clause is left out.' "$skill"
  grep -qF 'and `; Findings cover <sha>..HEAD; judge spec, gaps and criteria on the code at HEAD: the commits before <sha> were already reviewed` is appended' "$skill"
  ! grep -qF 'the prompt ends at `.review.json`' "$skill" || false
  ! grep -qF 'the prompt ends with `; the notes' "$skill" || false
}

@test "crew-review documents the optional notes input and the report's notes list, naming no caller" {
  local skill="$REPO_ROOT/skills/crew-review/SKILL.md"
  grep -qF '**Notes for a person**' "$skill"
  grep -qF 'a JSON file holding a list of strings' "$skill"
  grep -qF '"notes": [{"note": <0-based index into the notes list>, "settled": true|false, "why": "<one line>"}]' "$skill"
  grep -qF 'with no notes input, the report has no `notes` key' "$skill"
  ! grep -qi 'coder' "$skill" || false
  ! grep -v 'solve-feature:slug' "$skill" | grep -qi 'solve-feature' || false
}
