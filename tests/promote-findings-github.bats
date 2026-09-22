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
}

# ─── defer: github path ───────────────────────────────────────────────────────

@test "defer creates a github issue labeled ready-for-agent, milestoned to the feature slug" {
  configure_github
  stub_gh

  run bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md
  [ "$status" -eq 0 ]
  [[ "$output" == "defer: https://github.com/acme/widgets/issues/42" ]]

  grep -q -- '--title Fix review findings: a' "$GH_CALLS_LOG"
  grep -q -- '--label ready-for-agent' "$GH_CALLS_LOG"
  grep -q -- '--milestone feat' "$GH_CALLS_LOG"
  # No local issue file was ever written for the github path.
  [ -z "$(ls .scratch/feat/issues/open 2>/dev/null)" ]
}

@test "defer passes --repo through when the tracker doc overrides it" {
  configure_github "owner/name"
  stub_gh

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q -- '--repo owner/name' "$GH_CALLS_LOG"
}

@test "defer omits --repo when no override is configured, letting gh infer it" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  ! grep -q -- '--repo' "$GH_CALLS_LOG"
}

@test "the created issue's body carries the Source: line in local's exact convention" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^Source: .*sprint-review-1.md (crew/feat/a)$' "$GH_LAST_BODY"
}

@test "the created issue's body carries a ## Blocked by section when the finding is blocked" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md \
    --blocked-by 5 >/dev/null
  grep -q '^## Blocked by$' "$GH_LAST_BODY"
  grep -q '^- Issue #5$' "$GH_LAST_BODY"
}

@test "the created issue's body omits ## Blocked by when nothing blocks the finding" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  ! grep -q '## Blocked by' "$GH_LAST_BODY"
}

@test "defer bootstraps a missing milestone before creating the issue" {
  configure_github
  stub_gh "[]"

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  grep -q -- 'api repos/{owner}/{repo}/milestones' "$GH_CALLS_LOG"
  grep -q -- 'api repos/{owner}/{repo}/milestones -f title=feat' "$GH_CALLS_LOG"
  jq -e '.[0].title == "feat"' "$GH_MILESTONES_FILE" >/dev/null
}

@test "defer makes no milestone-create call when the milestone already exists" {
  configure_github
  stub_gh '[{"title": "feat"}]'

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  grep -q -- 'api repos/{owner}/{repo}/milestones$' "$GH_CALLS_LOG"
  ! grep -q -- '-f title=feat' "$GH_CALLS_LOG"
}

@test "defer's milestone bootstrap uses the repo override path when one is configured" {
  configure_github "owner/name"
  stub_gh "[]"

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
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

  run bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh api milestones list failed"* ]]
}

@test "defer still annotates the review report under github, same as local" {
  configure_github
  stub_gh

  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^## Promoted Findings' "$REPORT"
  grep -q -- '- crew/feat/a: CRITICAL → https://github.com/acme/widgets/issues/42' "$REPORT"
}

# ─── guard: github path ────────────────────────────────────────────────────────

@test "guard live-fetches the body under github and is promotable with no Source: line" {
  configure_github
  stub_gh
  printf 'Some body with no Source line.\n' > "$GH_VIEW_BODY_FILE"

  run bash "$PROMOTE" guard --issue 42
  [[ "$output" == *"promotable — severities: CRITICAL"* ]]
  grep -q '^issue view 42' "$GH_CALLS_LOG"
}

@test "guard is still the depth bound under github, checked against the live body" {
  configure_github
  stub_gh
  printf 'Source: some-report (some-branch)\n' > "$GH_VIEW_BODY_FILE"

  run bash "$PROMOTE" guard --issue 42
  [[ "$output" == *"skip — source-guarded"* ]]
}

@test "guard fails closed under github when the issue cannot be fetched" {
  configure_github
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$STUB/gh"

  run bash "$PROMOTE" guard --issue 999
  [[ "$output" == *"skip — issue not found: 999"* ]]
}

# ─── list/flush: github never parks, so both report none ─────────────────────

@test "flush reports none under github — defer never parks a github issue" {
  configure_github
  run bash "$PROMOTE" flush --feature-slug feat
  [ "$output" = "FLUSH: none" ]
}

@test "list reports none under github — defer never parks a github issue" {
  configure_github
  run bash "$PROMOTE" list --feature-slug feat
  [ "$output" = "DEFERRED: none" ]
}

# ─── the local path is unchanged ───────────────────────────────────────────────

@test "with no tracker doc at all, defer still writes a local file exactly as before" {
  run bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md
  [[ "$output" == "defer: .scratch/feat/issues/open/01-fix-findings-a.md" ]]
  [ -f .scratch/feat/issues/open/01-fix-findings-a.md ]
  grep -q '^Status: deferred-findings' .scratch/feat/issues/open/01-fix-findings-a.md
}
