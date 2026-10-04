#!/usr/bin/env bats

# promote-findings.sh's github wiring: cmd_defer's github branch, plus guard/list/flush
# continuing to work under `tracker: github` — see .scratch/github-issue-tracker/issues/
# open/07-promote-findings-github-wiring.md.
#
# `gh` is stubbed on PATH throughout; these tests pin argument construction and body
# content, not real GitHub behaviour.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"
PROMOTE="$AFK_SCRIPTS/promote-findings.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m initial
  export MAIN_ROOT="$TEMP_DIR"

  # promote-findings.sh reads the review report through review-rollup.mjs — point it at
  # the repo's own copy, since these fixtures exercise the script alone, not a full install.
  export CREW_REVIEW_ROLLUP="$REPO_ROOT/orchestrator/review-rollup.mjs"
  # Same reasoning for tracker-config.sh: point straight at the repo's own copy instead of
  # requiring a full install under .coding-crew/scripts/.
  export CREW_TRACKER_CONFIG="$REPO_ROOT/scripts/tracker/tracker-config.sh"
  # _defer_github's github path shells out to github.mjs's own create-issue CLI — point it
  # at the repo's own copy too, same reasoning.
  export CREW_GITHUB_TRACKER_CLI="$REPO_ROOT/orchestrator/lib/trackers/github.mjs"

  mkdir -p .scratch/feat/issues/open .scratch/feat/reviews
  export REPORT=.scratch/feat/reviews/sprint-review-1.md
  json=$(jq -n '{
    branch: "crew/feat/a", slug: "a", verdict: "all-met",
    findings: [{severity: "CRITICAL", location: "src/x.ts:12", criterion: "unchecked input"}]
  }')
  cat > "$REPORT" <<EOF
## Branch: crew/feat/a (a)

\`\`\`json
$json
\`\`\`
EOF
  printf -- '- [ ] validate input at src/x.ts:12\n' > crit.md

  STUB="$TEMP_DIR/stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"
  export GH_CALLS_LOG="$TEMP_DIR/gh-calls.log"
  export GH_LAST_BODY="$TEMP_DIR/gh-last-body.txt"
  export GH_VIEW_BODY_FILE="$TEMP_DIR/gh-view-body.txt"
  export GH_MILESTONES_FILE="$TEMP_DIR/gh-milestones.json"
  : > "$GH_CALLS_LOG"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# configure_github [repo] — writes the front-matter tracker-config.sh reads.
configure_github() {
  mkdir -p .coding-crew/docs
  {
    echo "---"
    echo "tracker: github"
    [ -n "${1:-}" ] && echo "repo: $1"
    echo "---"
  } > .coding-crew/docs/issue-tracker.md
}

# stub_gh [existing-milestones-json] — a fake `gh` on PATH. Handles the subcommands this
# script calls: `gh issue create` (captures argv and the --body-file content, prints a fake
# issue URL), `gh issue view <n> --json body -q .body` (prints back a canned body), and
# `gh api repos/.../milestones` (list returns $1, default `[]`; create logs the call and
# appends to GH_MILESTONES_FILE so a second list call in the same test observes it).
stub_gh() {
  local milestones="${1:-[]}"
  printf '%s' "$milestones" > "$GH_MILESTONES_FILE"
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS_LOG"
case "$1" in
  api)
    shift 2
    case "${1:-}" in
      -f)
        # milestone create: -f title=<slug> — record it as an existing milestone.
        title="${2#title=}"
        jq --arg t "$title" '. + [{title: $t}]' "$GH_MILESTONES_FILE" > "$GH_MILESTONES_FILE.tmp"
        mv "$GH_MILESTONES_FILE.tmp" "$GH_MILESTONES_FILE"
        echo "{}"
        ;;
      *)
        # milestone list
        cat "$GH_MILESTONES_FILE"
        ;;
    esac
    ;;
  *)
case "$1 $2" in
  "issue create")
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [ "${args[$i]}" = "--body-file" ]; then
        cp "${args[$((i + 1))]}" "$GH_LAST_BODY"
      fi
    done
    echo "https://github.com/acme/widgets/issues/42"
    ;;
  "issue view")
    cat "$GH_VIEW_BODY_FILE" 2>/dev/null
    ;;
  *)
    echo "gh-stub: unhandled invocation: $*" >&2
    exit 1
    ;;
esac
    ;;
esac
SH
  chmod +x "$STUB/gh"
  # github.mjs spawns gh from Node, which on Windows never reads a shebang and won't run a
  # .cmd, so the stub on PATH loses to the real gh.exe there; CREW_FAKE_GH hands it over.
  export CREW_FAKE_GH="$STUB/gh"
}

# ─── defer: github path ───────────────────────────────────────────────────────

@test "defer creates a github issue labeled ready-for-agent, milestoned to the feature slug" {
  configure_github
  stub_gh

  run bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md
  [ "$status" -eq 0 ]
  [[ "$output" == "defer: https://github.com/acme/widgets/issues/42" ]]

  grep -q -- '--title Fix review findings: a' "$GH_CALLS_LOG"
  grep -q -- '--label ready-for-agent' "$GH_CALLS_LOG"
  grep -q -- '--milestone feat' "$GH_CALLS_LOG"
  # No local issue file was ever written for the github path.
  [ -z "$(ls .scratch/feat/issues/open 2>/dev/null)" ]
}

@test "defer-integration creates a ready-for-agent issue in the milestone, with Source: naming it an integration fix" {
  configure_github
  stub_gh
  printf -- "- [ ] The project's checks pass on the merged feature branch\n" > integ.md

  run bash "$PROMOTE" defer-integration --feature-slug feat --report .scratch/feat/dispatch/_integration/verify.out \
    --criteria-file integ.md
  [ "$status" -eq 0 ]
  [[ "$output" == "defer-integration: https://github.com/acme/widgets/issues/42" ]]
  grep -q -- '--title Fix integration check: feat' "$GH_CALLS_LOG"
  grep -q -- '--label ready-for-agent' "$GH_CALLS_LOG"
  grep -q -- '--milestone feat' "$GH_CALLS_LOG"
  grep -q '^Source: integration check (integration)$' "$GH_LAST_BODY"
  grep -q "^- \[ \] The project's checks pass on the merged feature branch$" "$GH_LAST_BODY"
  [ -z "$(ls .scratch/feat/issues/open 2>/dev/null)" ]
}

@test "defer passes --repo through when the tracker doc overrides it" {
  configure_github "owner/name"
  stub_gh

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q -- '--repo owner/name' "$GH_CALLS_LOG"
}

@test "defer omits --repo when no override is configured, letting gh infer it" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  ! grep -q -- '--repo' "$GH_CALLS_LOG"
}

@test "the created issue's body carries a Source: line naming the review and branch, not a report path" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^Source: review (crew/feat/a)$' "$GH_LAST_BODY"
}

@test "the created issue's body carries a ## Blocked by section when the finding is blocked" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md \
    --blocked-by 5 >/dev/null
  grep -q '^## Blocked by$' "$GH_LAST_BODY"
  grep -q '^- Issue #5$' "$GH_LAST_BODY"
}

@test "the created issue's body omits ## Blocked by when nothing blocks the finding" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  ! grep -q '## Blocked by' "$GH_LAST_BODY"
}

@test "defer bootstraps a missing milestone before creating the issue" {
  configure_github
  stub_gh "[]"

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  grep -q -- 'api repos/{owner}/{repo}/milestones' "$GH_CALLS_LOG"
  grep -q -- 'api repos/{owner}/{repo}/milestones -f title=feat' "$GH_CALLS_LOG"
  jq -e '.[0].title == "feat"' "$GH_MILESTONES_FILE" >/dev/null
}

@test "defer makes no milestone-create call when the milestone already exists" {
  configure_github
  stub_gh '[{"title": "feat"}]'

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  grep -q -- 'api repos/{owner}/{repo}/milestones$' "$GH_CALLS_LOG"
  ! grep -q -- '-f title=feat' "$GH_CALLS_LOG"
}

@test "defer's milestone bootstrap uses the repo override path when one is configured" {
  configure_github "owner/name"
  stub_gh "[]"

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  grep -q -- 'api repos/owner/name/milestones' "$GH_CALLS_LOG"
}

@test "defer dies without creating an issue when the milestone list call fails" {
  configure_github
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$STUB/gh"

  run bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh api milestones list failed"* ]]
}

@test "defer still annotates the review report under github, same as local" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --severities "CRITICAL, HIGH" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^## Promoted Findings' "$REPORT"
  grep -q -- '- crew/feat/a: CRITICAL, HIGH → https://github.com/acme/widgets/issues/42' "$REPORT"
}

# ─── guard: github path ────────────────────────────────────────────────────────

@test "guard live-fetches the body under github and is eligible with no Source: line" {
  configure_github
  stub_gh
  printf 'Some body with no Source line.\n' > "$GH_VIEW_BODY_FILE"

  run bash "$PROMOTE" guard --issue 42 --severities actionable
  [[ "$output" == *"eligible — threshold: actionable"* ]]
  grep -q '^issue view 42' "$GH_CALLS_LOG"
}

@test "guard is still the depth bound under github, checked against the live body" {
  configure_github
  stub_gh
  printf 'Source: some-report (some-branch)\n' > "$GH_VIEW_BODY_FILE"

  run bash "$PROMOTE" guard --issue 42 --severities actionable
  [[ "$output" == *"skip — source-guarded"* ]]
}

@test "guard fails closed under github when the issue cannot be fetched" {
  configure_github
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$STUB/gh"

  run bash "$PROMOTE" guard --issue 999 --severities actionable
  [[ "$output" == *"skip — issue not found: 999"* ]]
}

# ─── list/flush: github never parks, so both report none ─────────────────────

@test "flush reports none under github - defer never parks a github issue" {
  configure_github
  run bash "$PROMOTE" flush --feature-slug feat
  [ "$output" = "FLUSH: none" ]
}

@test "list reports none under github - defer never parks a github issue" {
  configure_github
  run bash "$PROMOTE" list --feature-slug feat
  [ "$output" = "DEFERRED: none" ]
}

# ─── the local path is unchanged ───────────────────────────────────────────────

@test "with no tracker doc at all, defer still writes a local file exactly as before" {
  run bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md
  [[ "$output" == "defer: .scratch/feat/issues/open/01-fix-findings-a.md" ]]
  [ -f .scratch/feat/issues/open/01-fix-findings-a.md ]
  grep -q '^Status: deferred-findings' .scratch/feat/issues/open/01-fix-findings-a.md
}

# ─── github bodies embed their evidence, never a local path ──────────────────

# A realistic review block: the json sidecar, then the reviewer's prose per finding.
write_full_review() {
  json=$(jq -n '{
    branch: "crew/feat/a", slug: "a", verdict: "unmet",
    findings: [
      {severity: "CRITICAL", location: "src/x.ts:12", criterion: "validate input at src/x.ts:12", verdict: "actionable"},
      {severity: "LOW", location: "src/y.ts:3", criterion: "rename tmp", verdict: "dismiss"}
    ]
  }')
  cat > "$REPORT" <<EOF
## Branch: crew/feat/a (a)

\`\`\`json
$json
\`\`\`

[CRITICAL] Unchecked input reaches the shell
File: src/x.ts:12
Snippet:
~~~
exec(req.body.cmd)
~~~
Issue: a request with cmd="rm -rf /" runs it
Fix: validate cmd against an allow-list

[LOW] Poor variable name
File: src/y.ts:3
Snippet:
~~~
const tmp = 1
~~~
Issue: unclear name
Fix: rename it

## Branch: crew/feat/b (b)

\`\`\`json
{"branch": "crew/feat/b", "slug": "b", "verdict": "all-met", "findings": []}
\`\`\`
EOF
}

# `! grep` mid-test never fails a bats test (set -e ignores negations), so absence is checked
# by an explicit return.
absent() { if grep "$@" "$GH_LAST_BODY"; then return 1; fi; }

no_local_paths() {
  absent -E '(^|[ (`"])/(Users|home|tmp|private|var|root)/'
  absent -F '.scratch/'
  absent -F "$TEMP_DIR"
}

@test "defer embeds each promoted finding's full reviewer text under ## Review findings" {
  configure_github
  stub_gh
  write_full_review

  bash "$PROMOTE" defer --severities "CRITICAL" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^## Review findings$' "$GH_LAST_BODY"
  grep -q '^\[CRITICAL\] Unchecked input reaches the shell' "$GH_LAST_BODY"
  grep -q '^File: src/x.ts:12$' "$GH_LAST_BODY"
  grep -q '^exec(req.body.cmd)$' "$GH_LAST_BODY"
  grep -q '^Issue: a request with cmd=' "$GH_LAST_BODY"
  grep -q '^Fix: validate cmd against an allow-list$' "$GH_LAST_BODY"
  # The criterion is still there, and findings below the threshold are not promoted.
  grep -q '^- \[ \] validate input at src/x.ts:12$' "$GH_LAST_BODY"
  absent -q 'Poor variable name'
  # Another branch's block in the same report is not leaked in.
  absent -q 'crew/feat/b'
  # The json sidecar is not embedded.
  absent -q '"severity"'
  no_local_paths
}

@test "defer under actionable embeds a folded duplicate_of target's prose block beside an unrelated finding" {
  configure_github
  stub_gh
  json=$(jq -n '{branch: "crew/feat/a", slug: "a", verdict: "unmet",
    findings: [
      {severity: "MEDIUM", location: "src/x.ts:1", criterion: "bound the loop", verdict: "actionable"},
      {severity: "HIGH", location: "src/y.ts:9", criterion: "bound y loop", verdict: "actionable", duplicate_of: 0},
      {severity: "LOW", location: "src/z.ts:5", criterion: "rename z", verdict: "actionable"}]}')
  cat > "$REPORT" <<EOF
## Branch: crew/feat/a (a)

\`\`\`json
$json
\`\`\`

[MEDIUM] Unbounded loop
File: src/x.ts:1
Snippet:
~~~
while (true) {}
~~~
Issue: never ends
Fix: add a bound

[HIGH] Unbounded y loop
File: src/y.ts:9
Snippet:
~~~
for (;;) {}
~~~
Issue: same defect
Fix: add a bound

[LOW] Poor name
File: src/z.ts:5
Snippet:
~~~
const z = 1
~~~
Issue: unclear
Fix: rename
EOF

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^File: src/x.ts:1$' "$GH_LAST_BODY"
  grep -q '^while (true) {}$' "$GH_LAST_BODY"
  grep -q '^File: src/z.ts:5$' "$GH_LAST_BODY"
}

@test "defer keeps a finding whose snippet fence has column-0 '#' and '##' lines whole" {
  configure_github
  stub_gh
  json=$(jq -n '{branch: "crew/feat/a", slug: "a", verdict: "unmet",
    findings: [{severity: "MEDIUM", location: "src/run.sh:9", criterion: "quote the var", verdict: "actionable"}]}')
  cat > "$REPORT" <<EOF
## Branch: crew/feat/a (a)

\`\`\`json
$json
\`\`\`

[MEDIUM] Unquoted variable
File: src/run.sh:9
Snippet:
~~~
# build the target
cd $TARGET
## second comment
~~~
Issue: an empty TARGET changes to the wrong directory
Fix: quote and guard the variable

## Branch: crew/feat/b (b)

\`\`\`json
{"branch": "crew/feat/b", "slug": "b", "verdict": "all-met", "findings": []}
\`\`\`
EOF

  bash "$PROMOTE" defer --severities "CRITICAL, HIGH, MEDIUM" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^## Review findings$' "$GH_LAST_BODY"
  grep -q '^# build the target$' "$GH_LAST_BODY"
  grep -q '^## second comment$' "$GH_LAST_BODY"
  grep -q '^Issue: an empty TARGET changes to the wrong directory$' "$GH_LAST_BODY"
  grep -q '^Fix: quote and guard the variable$' "$GH_LAST_BODY"
  absent -q 'crew/feat/b'
}

@test "defer under the actionable rule embeds only the findings triage judged actionable" {
  configure_github
  stub_gh
  write_full_review

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q 'Unchecked input reaches the shell' "$GH_LAST_BODY"
  absent -q 'Poor variable name'
  no_local_paths
}

@test "defer lists the json findings when the review has no prose blocks" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^## Review findings$' "$GH_LAST_BODY"
  grep -q 'src/x.ts:12.* unchecked input' "$GH_LAST_BODY"
  no_local_paths
}

@test "defer scrubs absolute and .scratch paths quoted in a finding" {
  configure_github
  stub_gh
  write_full_review
  sed -i.bak "s#^Issue: unclear name#Issue: unclear name#; s#^Fix: validate cmd against an allow-list#Fix: see /Users/alice/proj/src/x.ts and $TEMP_DIR/.scratch/feat/notes.md#" "$REPORT"

  bash "$PROMOTE" defer --severities "CRITICAL" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^Fix: see .*x.ts' "$GH_LAST_BODY"
  no_local_paths
}

@test "defer-gaps embeds the audit's evidence for each missing requirement, with no local path" {
  configure_github
  stub_gh
  printf -- '- [ ] Users can export to CSV\n' > gaps.md
  cat > .scratch/feat/prd-audit.md <<'EOF'
Audit of the PRD against the merged work.

```json
{"covered": ["login"], "partial": [], "missing": [{"requirement": "CSV export", "detail": "No exporter exists under src/export/; grep for csv finds nothing"}], "superseded": []}
```
EOF

  run bash "$PROMOTE" defer-gaps --feature-slug feat --report .scratch/feat/prd-audit.md --criteria-file gaps.md
  [ "$status" -eq 0 ]
  [[ "$output" == "defer-gaps: https://github.com/acme/widgets/issues/42" ]]
  grep -q '^Source: PRD audit (prd-audit)$' "$GH_LAST_BODY"
  grep -q '^## PRD audit evidence$' "$GH_LAST_BODY"
  grep -q 'CSV export' "$GH_LAST_BODY"
  grep -q 'No exporter exists under src/export/' "$GH_LAST_BODY"
  grep -q '^- \[ \] Users can export to CSV$' "$GH_LAST_BODY"
  no_local_paths
}

@test "defer-integration embeds the tail of the failing output, truncated, with no local path" {
  configure_github
  stub_gh
  printf -- "- [ ] The project's checks pass on the merged feature branch\n" > integ.md
  mkdir -p .scratch/feat/dispatch/_integration
  {
    for i in $(seq 1 2000); do echo "noise line $i padding padding padding padding"; done
    echo "FAIL tests/foo.test.ts at $TEMP_DIR/.scratch/worktrees/x/tests/foo.test.ts:9"
    echo "AssertionError: expected 1 to equal 2 in /Users/alice/proj/src/foo.ts"
  } > .scratch/feat/dispatch/_integration/verify.out

  run bash "$PROMOTE" defer-integration --feature-slug feat --report .scratch/feat/dispatch/_integration/verify.out \
    --criteria-file integ.md
  [ "$status" -eq 0 ]
  grep -q '^## Failing output (tail)$' "$GH_LAST_BODY"
  grep -q 'AssertionError: expected 1 to equal 2' "$GH_LAST_BODY"
  absent -q 'noise line 1 '
  [ "$(wc -c < "$GH_LAST_BODY")" -lt 12000 ]
  no_local_paths
}

@test "guard still treats every github body promote-findings.sh writes as source-guarded" {
  configure_github
  stub_gh
  write_full_review
  printf -- '- [ ] gap\n' > gaps.md
  printf -- '- [ ] integ\n' > integ.md
  : > .scratch/feat/prd-audit.md
  : > .scratch/feat/verify.out

  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  cp "$GH_LAST_BODY" "$GH_VIEW_BODY_FILE"
  run bash "$PROMOTE" guard --issue 42 --severities actionable
  [[ "$output" == *"skip — source-guarded"* ]]

  bash "$PROMOTE" defer-gaps --feature-slug feat --report .scratch/feat/prd-audit.md --criteria-file gaps.md >/dev/null
  cp "$GH_LAST_BODY" "$GH_VIEW_BODY_FILE"
  run bash "$PROMOTE" guard --issue 42 --severities actionable
  [[ "$output" == *"skip — source-guarded"* ]]

  bash "$PROMOTE" defer-integration --feature-slug feat --report .scratch/feat/verify.out --criteria-file integ.md >/dev/null
  cp "$GH_LAST_BODY" "$GH_VIEW_BODY_FILE"
  run bash "$PROMOTE" guard --issue 42 --severities actionable
  [[ "$output" == *"skip — source-guarded"* ]]
}

@test "guard ignores a Source: line inside a code fence, under github" {
  configure_github
  stub_gh
  printf '## Problem\n\n```\nSource: .scratch/x/sprint-review-1.md (b)\n```\n\n~~~\nSource: y\n~~~\n' > "$GH_VIEW_BODY_FILE"
  run bash "$PROMOTE" guard --issue 42 --severities actionable
  [[ "$output" == *"eligible"* ]]
}
