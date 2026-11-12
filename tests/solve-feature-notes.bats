#!/usr/bin/env bats

# solve-feature.sh's notes for a person, kept in the run file .coding-crew/solve-feature/notes-<slug>.json that only the
# script writes: land adds the coder's, fix the fixer's, sync hands the reviewer the coder notes still standing, fix
# marks the ones the review settled, describe renders the PR body from the file (and the earlier runs' notes start
# copied from the previous body) and marks every entry rendered, and the next run's start drops those. Setup and the
# stubs: helpers/solve-feature.bash.

load helpers/solve-feature

D=.coding-crew/solve-feature
NF=.coding-crew/solve-feature/notes-feat.json
NOTES=.coding-crew/solve-feature/pr-10.coder-notes.json
LOCAL=.coding-crew/solve-feature/local-pr-feature_feat.md

no_publish() { mkdir -p "$HOME/.coding-crew" && echo '{"solveFeature":{"publish":false}}' > "$HOME/.coding-crew/config.json"; }
# coded_with_notes — #2's coder leaves a note with a ### heading of its own, #3's a plain one; both land.
coded_with_notes() {
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2
  printf '%s\n' '### Merge order' '' '- merge after the infra PR' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out next)" = 3 ]
  coder 3
  printf '%s\n' '- set the CREW_X repo variable' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 3 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = pr=10 ]
}
note2=$'### Merge order\n\n- merge after the infra PR'
note3='- set the CREW_X repo variable'
section() { sed -n "/^<!-- solve-feature:$1:begin -->\$/,/^<!-- solve-feature:$1:end -->\$/p" "${2:-$STATE/pr-body}"; }
# clean_review — a review round with nothing to fix, as fix leaves it for describe.
clean_review() { echo '[]' > "$D/pr-${1:-10}.attention.json"; }

# --- land ------------------------------------------------------------------------------------

@test "land adds a non-empty coder.notes.md to the run file as one coder entry under its ref and makes no gh pr edit call; pr= comes first" {
  coded_with_notes
  [ "$(jq -c . "$NF")" = "$(jq -cn --arg a "$note2" --arg b "$note3" '[{author: "coder", ref: "2", text: $a}, {author: "coder", ref: "3", text: $b}]')" ] || { cat "$NF"; return 1; }
  ! grep -q '^pr edit' "$STATE/gh.log" || false
  ! grep -q 'solve-feature:notes' "$STATE/pr-body" || false
}

@test "land re-run for the same ref after a stop leaves one coder entry for it, the coder's latest text" {
  land_ready
  echo '- first draft' > "$D/coder.notes.md"
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  [ "$(jq -c '[.[] | .text]' "$NF")" = '["- first draft"]' ]
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  # The reopened issue's coder keeps the file, and rewrites it.
  [ -s "$D/coder.notes.md" ]
  coder 2
  echo '- second draft' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c . "$NF")" = '[{"author":"coder","ref":"2","text":"- second draft"}]' ]
}

@test "land with no or an empty coder.notes.md adds no entry" {
  land_ready
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat; coder 3
  : > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 3 feature/feat; [ "$status" -eq 0 ]
  [ ! -e "$NF" ]
}

@test "a land that stops after its coder wrote a note writes result.json with that note, the stop names the run file, and start keeps it" {
  land_ready
  echo '- set the CREW_X repo variable' > "$D/coder.notes.md"
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"$WORK/$NF"* ]] || { echo "$output"; return 1; }
  [ "$(jq -c .needs_attention "$D/result.json")" = '[{"type":"note","author":"coder","text":"- set the CREW_X repo variable"}]' ]
  # Another feature's notes in the shared directory never reach this feature's result.json.
  echo '[{"author":"coder","ref":"9","text":"other"}]' > "$D/notes-other.json"
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  [ "$(jq -c '[.[] | .text]' "$NF")" = '["- set the CREW_X repo variable"]' ]
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next feat; coder 3
  refuse_pushes
  run bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 1 ]
  [ "$(jq -c .needs_attention "$D/result.json")" = '[{"type":"note","author":"coder","text":"- set the CREW_X repo variable"}]' ]
}

@test "a stop with no note names no run file" {
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" != *"notes-feat.json"* ]] || { echo "$output"; return 1; }
}

# --- fix and reviewed ------------------------------------------------------------------------

@test "fix keeps exactly one fixer entry, the newest; a round-2 fixer that leaves no note drops it; reviewed names the standing note from round 2" {
  fix_ready
  echo '- rotate the CI token after merge' > "$D/pr-10.notes.md"
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$output" = findings=2 ] || { echo "$output"; return 1; }
  : > "$STATE/gh.log"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr edit' "$STATE/gh.log" || false
  [ "$(jq -c . "$NF")" = '[{"author":"fixer","round":0,"text":"- rotate the CI token after merge"}]' ]
  [ ! -e "$D/pr-10.notes.md" ]
  # Round 2: reviewed hands the fixer the standing note to keep, edit or drop.
  rereview
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$(printf 'fixer-note=%s\nfindings=2' "$WORK/$D/pr-10.prev-fixer-note.md")" ] || { echo "$output"; return 1; }
  [ "$(cat "$D/pr-10.prev-fixer-note.md")" = '- rotate the CI token after merge' ]
  echo '- rotate the CI token, then the deploy key' > "$D/pr-10.notes.md"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c . "$NF")" = '[{"author":"fixer","round":1,"text":"- rotate the CI token, then the deploy key"}]' ]
  # A third fix with findings and no note: the fixer dropped it.
  rereview
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$NF" ] || [ "$(jq -c '[.[] | select(.author == "fixer")]' "$NF")" = '[]' ]
}

@test "reviewed names no fixer note in round 1, nor once none stands" {
  fix_ready
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$output" = findings=2 ]
  run bash "$SCRIPT" fix feat 10 feature/feat; [ "$status" -eq 0 ]
  rereview
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$output" = findings=2 ] || { echo "$output"; return 1; }
  [ ! -e "$D/pr-10.prev-fixer-note.md" ]
}

@test "a re-run's first round hands its fixer the note a stopped fix left, so the note is kept, edited or dropped, not lost" {
  fix_ready
  echo '- rotate the CI token after merge' > "$D/pr-10.notes.md"
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(jq -c . "$NF")" = '[{"author":"fixer","round":0,"text":"- rotate the CI token after merge"}]' ]
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  report '{"spec":"met","gaps":[],"findings":[{"severity":"LOW","location":"a:1","issue":"i","fix":"f"}]}'
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$(printf 'fixer-note=%s\nfindings=1' "$WORK/$D/pr-10.prev-fixer-note.md")" ] || { echo "$output"; return 1; }
  [ "$(cat "$D/pr-10.prev-fixer-note.md")" = '- rotate the CI token after merge' ]
}

@test "a second round with no findings runs no fixer, so the first round's fixer note stands" {
  fix_ready
  echo '- decide whether to check each comment author' > "$D/pr-10.notes.md"
  run bash "$SCRIPT" fix feat 10 feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[]}'
  run bash "$SCRIPT" fix feat 10 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.[] | .text]' "$NF")" = '["- decide whether to check each comment author"]' ]
}

@test "SKILL.md's fixer prompt names reviewed's fixer-note file to keep, edit or drop" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'fixer-note=<path>' "$skill"
  grep -qF 'keep, edit or drop this note' "$skill"
}

# --- sync and the review's settled notes -----------------------------------------------------

@test "sync writes the standing coder notes' texts from the run file, never reading the PR body; with none it leaves no file" {
  coded_with_notes
  # A fixer's entry is no coder note.
  jq '. + [{author: "fixer", round: 0, text: "- rotate the key"}]' "$NF" > "$NF.new" && mv "$NF.new" "$NF"
  : > "$STATE/gh.log"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c . "$NOTES")" = "$(jq -cn --arg a "$note2" --arg b "$note3" '[$a, $b]')" ] || { cat "$NOTES"; return 1; }
  ! grep -q -- '--json body' "$STATE/gh.log" || false
  # None standing: a stale file goes.
  echo '[{"author":"fixer","round":0,"text":"x"}]' > "$NF"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$NOTES" ]
}

@test "fix marks the k-th note of pr-<n>.coder-notes.json settled with its why, then that file lists only the notes still standing, for round 2" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"both issues landed on this branch"},{"note":1,"settled":false,"why":"a repo variable only a person can set"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.[] | [.ref, .settled, .why]]' "$NF")" = '[["2",true,"both issues landed on this branch"],["3",null,null]]' ]
  [ "$(jq -c . "$NOTES")" = "$(jq -cn --arg b "$note3" '[$b]')" ]
  # Round 2 judges only the note still standing, by its index in the rewritten file.
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"the variable is set by the workflow"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$NOTES" ]
  [ "$(jq -c '[.[] | .why]' "$NF")" = '["both issues landed on this branch","the variable is set by the workflow"]' ]
}

@test "an entry off its shape or out of range settles nothing" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  cp "$NF" "$STATE/synced-nf"; cp "$NOTES" "$STATE/synced-notes"
  local rep
  for rep in '' ',"notes":[]' ',"notes":"all settled"' ',"notes":[{"note":"0","settled":true,"why":"w"}]' \
    ',"notes":[{"note":5,"settled":true,"why":"w"}]' ',"notes":[{"note":-1,"settled":true,"why":"w"}]' \
    ',"notes":[{"note":0,"settled":"true","why":"w"}]' ',"notes":[{"note":0,"settled":true}]' \
    ',"notes":[{"note":0,"settled":false,"why":"w"}]' ',"notes":[{"note":0.5,"settled":true,"why":"w"}]' ',"notes":["0"]'; do
    cp "$STATE/synced-nf" "$NF"; cp "$STATE/synced-notes" "$NOTES"
    report "{\"spec\":\"met\",\"gaps\":[],\"findings\":[]$rep}"
    run bash "$SCRIPT" fix feat 10 feature/feat
    [ "$status" -eq 0 ] || { echo "$rep fix: $output"; return 1; }
    [ "$(jq '[.[] | select(.settled)] | length' "$NF")" = 0 ] || { echo "$rep: settled"; return 1; }
    run bash "$SCRIPT" describe feat 10
    [ "$output" = "needs-attention pr=10" ] || { echo "$rep: $output"; return 1; }
    [ "$(jq -c '[.needs_attention[] | .author]' "$D/result.json")" = '["coder","coder"]' ] || { echo "$rep"; jq -c .needs_attention "$D/result.json"; return 1; }
  done
}

@test "a fix re-run after a stop settles each note once" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"merged together"}]}'
  echo fixed > fixed.txt
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  [ "$(jq '[.[] | select(.settled)] | length' "$NF")" = 0 ]
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c '[.[] | .settled]' "$NF")" = '[true,null]' ]
}

# --- describe --------------------------------------------------------------------------------

@test "describe renders the standing notes, then the settled ones with their why, holds the draft on a standing note, and marks every entry rendered" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"both issues\nlanded here"}]}'
  echo '- rotate the key' > "$D/pr-10.notes.md"
  run bash "$SCRIPT" fix feat 10 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "needs-attention pr=10" ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready 10' "$STATE/gh.log" || false
  [ "$(section notes)" = "$(printf '%s\n' '<!-- solve-feature:notes:begin -->' '## Notes for a person' '' 'Delete a note here once it is handled.' '' \
    '### the coder of 3' '' "$note3" '' "### the fixer of PR #10's review" '' '- rotate the key' '' '<!-- solve-feature:notes:end -->')" ] || { cat "$STATE/pr-body"; return 1; }
  [ "$(section settled)" = "$(printf '%s\n' '<!-- solve-feature:settled:begin -->' '## Settled by the review' '' \
    '### the coder of 2' '' "$note2" '' 'Settled by the review: both issues landed here' '' '<!-- solve-feature:settled:end -->')" ] || { cat "$STATE/pr-body"; return 1; }
  grep -qx -- '- notes for a person, in the section below: delete each once it is handled' "$STATE/pr-body"
  [ "$(jq -c '[.needs_attention[] | [.author, .text]]' "$D/result.json")" = "$(jq -cn --arg b "$note3" '[["coder", $b], ["fixer", "- rotate the key"]]')" ]
  [ "$(jq '[.[] | select(.rendered != true)] | length' "$NF")" = 0 ]
  # A second describe writes the same body, and result.json still carries the notes.
  cp "$STATE/pr-body" "$STATE/first-body"
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "needs-attention pr=10" ]
  diff "$STATE/first-body" "$STATE/pr-body"
  [ "$(jq '[.needs_attention[] | select(.type == "note")] | length' "$D/result.json")" = 2 ]
}

@test "a run whose notes were all settled ends ready" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"w0"},{"note":1,"settled":true,"why":"w1"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "ready pr=10" ] || { echo "$output"; cat "$STATE/pr-body"; return 1; }
  [ "$(jq -c .needs_attention "$D/result.json")" = '[]' ]
  ! grep -q '^## Needs attention$\|solve-feature:notes' "$STATE/pr-body" || false
  [ "$(grep -c '^Settled by the review: ' "$STATE/pr-body")" = 2 ]
}

@test "a failed body write marks nothing rendered, so the next start keeps the notes" {
  coded_with_notes
  clean_review
  GH_EDIT_FAIL=1 run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [ "$(jq '[.[] | select(.rendered)] | length' "$NF")" = 0 ]
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  [ "$(jq length "$NF")" = 2 ]
}

@test "the next run's start drops rendered entries and carries the previous body's notes, settled and earlier sections into one flat Earlier runs' notes section that holds no draft" {
  coded_with_notes
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[],"notes":[{"note":0,"settled":true,"why":"w0"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" describe feat 10; [ "$output" = "needs-attention pr=10" ]
  # Two more runs, each with nothing new: no heading nests, each note's text appears once.
  local n
  for n in 1 2; do
    run bash "$SCRIPT" start feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$NF" ]
    clean_review
    run bash "$SCRIPT" describe feat 10
    [ "$output" = "ready pr=10" ] || { echo "run $n: $output"; cat "$STATE/pr-body"; return 1; }
    [ "$(grep -c "^## Earlier runs' notes\$" "$STATE/pr-body")" = 1 ]
    ! grep -q '^## Notes for a person$\|^## Settled by the review$\|^Delete a note here' "$STATE/pr-body" || { cat "$STATE/pr-body"; return 1; }
    [ "$(grep -c -- '^- merge after the infra PR$' "$STATE/pr-body")" = 1 ]
    [ "$(grep -c -- "^$note3\$" "$STATE/pr-body")" = 1 ]
    [ "$(grep -c '^Settled by the review: w0$' "$STATE/pr-body")" = 1 ]
    [ "$(grep -c '^<!-- solve-feature:earlier:begin -->$' "$STATE/pr-body")" = 1 ]
    [ "$(jq -c .needs_attention "$D/result.json")" = '[]' ]
  done
  [ "$(section earlier | sed -n 2p)" = "## Earlier runs' notes" ]
}

@test "a start that stops before its first step drops the rendered entries, so its result.json lists no note the body holds" {
  coded_with_notes
  clean_review
  run bash "$SCRIPT" describe feat 10; [ "$output" = "needs-attention pr=10" ]
  touch stray
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" != *"$NF"* ]] || { echo "$output"; return 1; }
  [ ! -e "$NF" ]
  [ "$(jq -c .needs_attention "$D/result.json")" = '[]' ] || { cat "$D/result.json"; return 1; }
}

@test "a note a person deleted from the previous body does not come back, and a new note of this run holds the draft beside the earlier ones" {
  coded_with_notes
  clean_review
  run bash "$SCRIPT" describe feat 10; [ "$output" = "needs-attention pr=10" ]
  perl -0pi -e 's/### the coder of 3\n\n- set the CREW_X repo variable\n\n//' "$STATE/pr-body"
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  echo '- a note of this run' > "$D/pr-10.notes.md"
  report '{"spec":"met","gaps":[],"findings":[]}'
  run bash "$SCRIPT" fix feat 10 feature/feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "needs-attention pr=10" ] || { echo "$output"; return 1; }
  ! grep -q 'CREW_X' "$STATE/pr-body" || false
  section earlier | grep -qx -- '- merge after the infra PR'
  section notes | grep -qx -- '- a note of this run'
  [ "$(jq -c '[.needs_attention[] | .text]' "$D/result.json")" = '["- a note of this run"]' ]
}

@test "with publish false start calls no gh and copies earlier notes from the local body file only" {
  no_publish
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat; coder 2
  echo '- tag a release once this merges' > "$D/coder.notes.md"
  run bash "$SCRIPT" land feat 2 feature/feat; [ "${lines[0]}" = pr=local ] || { echo "$output"; return 1; }
  clean_review local
  run bash "$SCRIPT" describe feat local; [ "$output" = "needs-attention branch=feature/feat" ] || { echo "$output"; return 1; }
  section notes "$LOCAL" | grep -qx -- '- tag a release once this merges'
  # A person saved the local body with CRLF line endings.
  perl -pi -e 's/\n/\r\n/' "$LOCAL"
  : > "$STATE/gh.log"
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -s "$STATE/gh.log" ]
  [ "$(cat "$D/earlier-feat.md" | grep -v '^$')" = "$(printf '%s\n' '### the coder of 2' '- tag a release once this merges')" ] || { cat -A "$D/earlier-feat.md"; return 1; }
  clean_review local
  run bash "$SCRIPT" describe feat local
  [ "$output" = "ready branch=feature/feat" ] || { echo "$output"; return 1; }
  section earlier "$LOCAL" | grep -qx -- '- tag a release once this merges'
}

@test "post_notes, NOTE_BLOCKS and settle_notes' body matching are gone" {
  local s="$REPO_ROOT/skills/solve-feature/scripts/solve-feature.sh"
  ! grep -qE 'post_notes|NOTE_BLOCKS|settled-body|notes-body' "$s" || false
}

# --- the prompts -----------------------------------------------------------------------------

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
