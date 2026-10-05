#!/usr/bin/env bats

# promote-findings.sh open, and post-findings.sh — the open findings as JSON, and their one
# PR review. `gh` is stubbed on PATH: it serves a fixed diff and keeps every review posted to
# it in $GH_STORE, so a second run sees what the first one put on the PR.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
PROMOTE="$REPO_ROOT/skills/crew-afk/scripts/promote-findings.sh"
POST="$REPO_ROOT/skills/crew-afk/scripts/post-findings.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR MAIN_ROOT="$TEMP_DIR"
  cd "$TEMP_DIR"
  export CREW_REVIEW_ROLLUP="$REPO_ROOT/orchestrator/review-rollup.mjs"
  export FEATURE_BRANCH=feature/feat FEATURE_SLUG=feat
  mkdir -p .scratch/feat/reviews/done
  export REPORT=.scratch/feat/reviews/sprint-review-1.md
  write_report "$REPORT" crew/feat/a '[
    {"severity":"CRITICAL","location":"src/x.ts:12","criterion":"unchecked input"},
    {"severity":"HIGH","location":"src/y.ts:40","criterion":"trust boundary crossed"},
    {"severity":"LOW","location":"free text somewhere","criterion":"a nit"}]'

  export GH_STORE="$TEMP_DIR/store.jsonl" GH_LOG="$TEMP_DIR/gh.log"
  : > "$GH_STORE"; : > "$GH_LOG"
  mkdir -p stub
  cat > stub/gh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view") echo '{"number":7,"state":"OPEN"}' ;;
  "repo view") echo "o/r" ;;
  "pr diff") cat <<'DIFF'
diff --git a/src/x.ts b/src/x.ts
--- a/src/x.ts
+++ b/src/x.ts
@@ -10,3 +10,4 @@ ctx
 ten
 eleven
+twelve
 thirteen
diff --git a/src/y.ts b/src/y.ts
--- a/src/y.ts
+++ b/src/y.ts
@@ -1,2 +1,2 @@
-old
+new
 keep
DIFF
    ;;
  "api repos/o/r/pulls/7/reviews")
    if [[ " $* " == *" POST "* ]]; then
      input=""; while [ $# -gt 0 ]; do [ "$1" = "--input" ] && input="$2"; shift; done
      jq -c . "$input" >> "$GH_STORE"
    else
      jq -s '[.[] | {body}]' "$GH_STORE"
    fi ;;
  "api repos/o/r/pulls/7/comments") jq -s '[.[].comments[] | {body}]' "$GH_STORE" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x stub/gh
  export PATH="$TEMP_DIR/stub:$PATH"
}

teardown() { cd /; rm -r "$TEMP_DIR"; }

write_report() { # file branch findings-json
  local json
  json=$(jq -n --arg b "$2" --argjson f "$3" '{branch: $b, slug: "a", verdict: "all-met", findings: $f}')
  printf '## Branch: %s (a)\n\n```json\n%s\n```\n' "$2" "$json" > "$1"
}

@test "open prints every open finding as JSON" {
  run bash "$PROMOTE" open --feature-slug feat
  [ "$status" -eq 0 ]
  [ "$(jq length <<< "$output")" -eq 3 ]
  [ "$(jq -r '.[0] | [.branch, .severity, .location, .criterion] | join("|")' <<< "$output")" = "crew/feat/a|CRITICAL|src/x.ts:12|unchecked input" ]
}

@test "open drops promoted (branch, severity) pairs and ignores reviews/done" {
  printf '\n## Promoted Findings\n\n- crew/feat/a: CRITICAL, HIGH → .scratch/feat/issues/open/02-fix.md\n' >> "$REPORT"
  cp "$REPORT" .scratch/feat/reviews/done/old.md
  run bash "$PROMOTE" open --feature-slug feat
  [ "$(jq -r 'map(.severity) | join(",")' <<< "$output")" = "LOW" ]
}

@test "open drops promoted pairs from a marker that carries a finding count" {
  printf '\n## Promoted Findings\n\n- crew/feat/a: CRITICAL, HIGH → https://github.com/acme/widgets/issues/42 (2 finding(s))\n' >> "$REPORT"
  run bash "$PROMOTE" open --feature-slug feat
  [ "$(jq -r 'map(.severity) | join(",")' <<< "$output")" = "LOW" ]
}

@test "open prints [] with no reports" {
  rm "$REPORT"
  run bash "$PROMOTE" open --feature-slug feat
  [ "$output" = "[]" ]
}

@test "post-findings posts one review: inline inside the diff, the rest in the body" {
  run bash "$POST"
  [ "$status" -eq 0 ]
  [ "$output" = "POSTED: 3 (1 inline)" ]
  [ "$(wc -l < "$GH_STORE")" -eq 1 ]
  [ "$(jq -r '.event' "$GH_STORE")" = "COMMENT" ]
  # src/y.ts:40 is outside y.ts's hunk, so only src/x.ts:12 is inline
  [ "$(jq -r '.comments | map("\(.path):\(.line)") | join(",")' "$GH_STORE")" = "src/x.ts:12" ]
  jq -e '.body | contains("### HIGH") and contains("src/y.ts:40") and contains("### LOW") and contains("crew-finding:")' "$GH_STORE"
}

@test "a second run posts nothing; a new finding is the only one posted" {
  bash "$POST" >/dev/null
  run bash "$POST"
  [ "$output" = "POSTED: 0 (0 inline)" ]
  [ "$(wc -l < "$GH_STORE")" -eq 1 ]

  write_report .scratch/feat/reviews/sprint-review-2.md crew/feat/b '[{"severity":"MEDIUM","location":"src/x.ts:11","criterion":"new one"}]'
  run bash "$POST"
  [ "$output" = "POSTED: 1 (1 inline)" ]
  [ "$(wc -l < "$GH_STORE")" -eq 2 ]
}

@test "post-findings with no open findings posts nothing" {
  rm "$REPORT"
  run bash "$POST"
  [ "$output" = "POSTED: 0 (0 inline)" ]
  [ ! -s "$GH_STORE" ]
}

@test "a triaged finding names its verdict and rationale inline and in the body; an untriaged one names neither" {
  write_report "$REPORT" crew/feat/a '[
    {"severity":"HIGH","location":"src/x.ts:11","criterion":"inline one","verdict":"debatable","rationale":"renames an export"},
    {"severity":"HIGH","location":"nowhere","criterion":"body one","verdict":"dismiss","rationale":"already guarded"},
    {"severity":"LOW","location":"nowhere","criterion":"no-verdict one"}]'
  run bash "$POST"
  [ "$output" = "POSTED: 3 (1 inline)" ]
  jq -e '.comments[0].body | contains("triage: debatable — renames an export")' "$GH_STORE"
  jq -e '.body | contains("body one (`crew/feat/a`) — triage: dismiss — already guarded")' "$GH_STORE"
  jq -e '.body | contains("Dismissed by triage") | not' "$GH_STORE"
  jq -e '[.body | split("\n")[] | select(contains("no-verdict one"))] | length == 1 and (.[0] | contains("triage") | not)' "$GH_STORE"
  run bash "$POST"
  [ "$output" = "POSTED: 0 (0 inline)" ]
}

@test "a finding's issue text precedes its criterion in the inline comment and the body" {
  write_report .scratch/feat/reviews/sprint-review-3.md crew/feat/c '[
    {"severity":"MEDIUM","location":"src/x.ts:11","issue":"PROBLEM-A","criterion":"FIX-A"},
    {"severity":"MEDIUM","location":"nowhere","issue":"PROBLEM-B","criterion":"FIX-B"}]'
  run bash "$POST"
  [ "$status" -eq 0 ]
  jq -e '.comments | map(select(.body | test("PROBLEM-A.*FIX-A"))) | length == 1' "$GH_STORE"
  jq -e '.body | test("PROBLEM-B.*FIX-B")' "$GH_STORE"
}

@test "a finding already posted under the old body format is not posted again" {
  key="crew/feat/a|CRITICAL|src/x.ts:12|unchecked input"
  marker="crew-finding:$(printf '%s' "$key" | { if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi; } | cut -c1-12)"
  jq -nc --arg b "- \`src/x.ts:12\` — unchecked input (\`crew/feat/a\`) <!-- $marker -->" '{event:"COMMENT",body:$b,comments:[]}' > "$GH_STORE"
  write_report "$REPORT" crew/feat/a '[{"severity":"CRITICAL","location":"src/x.ts:12","issue":"new issue text","criterion":"unchecked input"}]'
  run bash "$POST"
  [ "$output" = "POSTED: 0 (0 inline)" ]
}

@test "a carried finding is passed through by open and labelled (earlier review) in the posted review" {
  write_report "$REPORT" crew/feat/a '[
    {"severity":"LOW","location":"free text","criterion":"a nit","carried":true},
    {"severity":"HIGH","location":"free text two","criterion":"a fresh one"}]'
  run bash "$PROMOTE" open --feature-slug feat
  [ "$(jq -r '[.[] | .carried] | @json' <<< "$output")" = "[true,null]" ]

  PATH="$TEMP_DIR/stub:$PATH" run bash "$POST"
  [ "$status" -eq 0 ]
  body=$(jq -r '.body' "$GH_STORE")
  [[ "$body" == *"a nit (earlier review)"* ]]
  [[ "$body" != *"a fresh one (earlier review)"* ]]
}

@test "a report_only feature finding stays open though a '- feature: actionable' bullet covers its verdict" {
  write_report "$REPORT" feature '[
    {"severity":"HIGH","location":"a.ts:1","criterion":"promoted","verdict":"actionable"},
    {"severity":"HIGH","location":"b.ts:2","criterion":"report only","verdict":"actionable","report_only":true}]'
  printf '\n## Promoted Findings\n\n- feature: actionable → #9\n' >> "$REPORT"
  run bash "$PROMOTE" open --feature-slug feat
  [ "$(jq -r '[.[] | .criterion] | @json' <<< "$output")" = '["report only"]' ]
}

@test "open still lists an earlier version's open branch findings, and nothing promotes them" {
  # A real report from before per-branch review stopped raising findings (PRD D10): its
  # branch blocks' open findings are posted or reminded, never made a fix issue.
  rm "$REPORT"
  mkdir -p .scratch/feat/issues/open
  cp "$REPO_ROOT"/tests/fixtures/review-carry/sprint-review-*.md .scratch/feat/reviews/
  run bash "$PROMOTE" open --feature-slug feat
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.[] | select(.branch | startswith("crew/feature-area-review/198-"))] | length == 1'
  echo "$output" | jq -e '.[] | select(.location == "CLAUDE.md:165") | .severity == "LOW"'
  run bash "$PROMOTE" flush --feature-slug feat
  [ "$output" = "FLUSH: none" ]
  [ -z "$(ls .scratch/feat/issues/open)" ]
  # No code path promotes a branch's findings: the only defer the orchestrator runs is the feature review's.
  ! grep -rn '"defer",' "$REPO_ROOT/orchestrator/lib" | grep -v 'pipeline/feature-review.mjs'
}
