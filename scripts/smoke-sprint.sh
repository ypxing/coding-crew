#!/usr/bin/env bash
set -uo pipefail

# smoke-sprint.sh — run one real crew-afk sprint end to end on one platform, from a fresh repo.
#
# Usage: scripts/smoke-sprint.sh <claude|copilot|pi|codex> [--demo] [--dir <path>] [--setup-only] [-- <crew-afk run args>...]
#
# Builds a throwaway git repo from scripts/smoke-sprint/template/ (a tiny Node project, `npm test`
# = `node --test`) with one ready issue from scripts/smoke-sprint/feature/ (`.scratch/subtract/`:
# add `sub()`), installs crew-afk for <platform> from this checkout, runs `doctor`, then
# `crew-afk run --feature-slug subtract`, and checks the outcome:
#   - crew-afk exited 0
#   - the issue is in `.scratch/subtract/issues/done/`
#   - `feature/subtract` exports `sub` and its `node --test` passes
# Prints `SMOKE: PASS (<platform>)` (`SMOKE: PASS (<platform>, demo)` under --demo, the only PASS
# line cut-release.sh --demo-smoke accepts) / `SMOKE: FAIL: <why>`; exit 0 / 1, 2 on a usage error. Every run also prints
# `crew-afk-version: <v>` (this checkout's registry.json), which cut-release.sh --demo-smoke reads back.
#
# --demo runs the sprint on a pinned outside demo project instead, laid out in
# scripts/smoke-sprint/demo/ (CREW_DEMO_DIR overrides the directory):
#   repo     clone URL (CREW_DEMO_REPO overrides it, and then the file may be absent)
#   sha      the commit to clone at, checked out as `main`; the clone's remote is removed, so the
#            sprint can neither sync newer demo commits in nor push anything back
#   check    the project's own checks, one shell command per line (blank and `#` lines skipped)
#   feature/ the demo's `.scratch/<slug>/` (PRD and issues), copied to `.scratch/<slug>/`
#   slug     optional, the feature slug (default `demo`)
# PASS needs crew-afk to exit 0, every issue under `issues/done/`, and every `check` command to exit
# 0 on `feature/<slug>`. A missing demo file is a usage error (exit 2). A demo run past --setup-only
# appends `| version | date | PASS/FAIL | cost | dispatch-hours | findings |` to
# scripts/smoke-sprint/RESULTS.md (CREW_SMOKE_RESULTS overrides the file).
#
# Repeatable: the repo is rebuilt from the template on every run, so no branch, sprint state or
# dev-commands cache from an earlier run leaks in. The directory (default
# ${TMPDIR:-/tmp}/crew-smoke-<platform>) is deleted first only when it is an earlier smoke repo
# (`.git/crew-smoke` marker); any other existing path is refused. The crew-afk log is kept at
# <dir>/.git/crew-smoke/run.log. --setup-only stops after install (no CLI call, no API cost).
#
# A results row is committed by hand: cut-release.sh needs a clean tree, so write the log outside
# the checkout (e.g. >"${TMPDIR:-/tmp}/smoke.log") and commit RESULTS.md before cutting the release.
#
# Maintainer-only: ships to no consumer. A real run calls the platform's CLI and costs money.

PLATFORMS=(claude copilot pi codex)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FIXTURES="$SCRIPT_DIR/smoke-sprint"
SLUG=subtract
RECORD=0

usage() { echo "usage: $0 <claude|copilot|pi|codex> [--demo] [--dir <path>] [--setup-only] [-- <crew-afk run args>...]" >&2; exit 2; }
fail() { record FAIL; echo "SMOKE: FAIL: $*"; exit 1; }

# One results row for a demo run that reached the sprint: cost and dispatch time from the sprint
# state, findings counted from the review reports.
record() {
  [[ $RECORD -eq 1 ]] || return 0
  RECORD=0
  local results="${CREW_SMOKE_RESULTS:-$FIXTURES/RESULTS.md}" stats findings
  stats=$(node -e '
    let d = []; try { d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).dispatches || []; } catch {}
    const sum = (k) => d.reduce((a, x) => a + (Number(x[k]) || 0), 0);
    console.log(`$${sum("cost_usd").toFixed(2)} | ${(sum("duration_ms") / 3600000).toFixed(2)}`);
  ' "$DIR/.scratch/$SLUG/sprint-state.json" 2>/dev/null) || stats="? | ?"
  # Folded as crew-afk's own summary folds them (review-rollup.mjs: one record per branch, latest
  # wins), so a finding a later review block repeats is counted once.
  findings=$(node "$ROOT/orchestrator/review-rollup.mjs" "$DIR/.scratch/$SLUG/reviews/"sprint-review-*.md 2>/dev/null \
    | node -e 'let s = ""; process.stdin.on("data", (c) => (s += c)).on("end", () =>
        console.log(JSON.parse(s).branches.reduce((n, b) => n + (b.findings || []).length, 0)))' 2>/dev/null) \
    || findings='?'
  echo "| $VERSION | $(date -u +%Y-%m-%d) | $1 | $stats | $findings |" >>"$results" \
    || echo "SMOKE: warning: cannot append to $results" >&2
}

PLATFORM="${1:-}"
[[ " ${PLATFORMS[*]} " == *" $PLATFORM "* && -n "$PLATFORM" ]] || usage
shift
DIR="" SETUP_ONLY=0 DEMO=0 EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --demo) DEMO=1; shift ;;
    --dir) [[ $# -ge 2 ]] || usage; DIR="$2"; shift 2 ;;
    --setup-only) SETUP_ONLY=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    *) usage ;;
  esac
done
DIR="${DIR:-${TMPDIR:-/tmp}/crew-smoke-$PLATFORM$([[ $DEMO -eq 1 ]] && echo -demo)}"
# Absolute from here on: the script cds into the repo, and record() and install.sh read paths under it.
[[ "$DIR" == /* ]] || DIR="$PWD/$DIR"

VERSION=$(node -p 'require(process.argv[1]).skills["crew-afk"].version' "$ROOT/registry.json" 2>/dev/null) \
  || VERSION=unknown
echo "crew-afk-version: $VERSION"

if [[ $DEMO -eq 1 ]]; then
  DEMO_DIR="${CREW_DEMO_DIR:-$FIXTURES/demo}"
  missing=()
  [[ -n "${CREW_DEMO_REPO:-}" || -s "$DEMO_DIR/repo" ]] || missing+=("$DEMO_DIR/repo")
  for f in sha check; do [[ -s "$DEMO_DIR/$f" ]] || missing+=("$DEMO_DIR/$f"); done
  [[ -d "$DEMO_DIR/feature" ]] || missing+=("$DEMO_DIR/feature/")
  if [[ ${#missing[@]} -gt 0 ]]; then
    for f in "${missing[@]}"; do echo "smoke-sprint: --demo: missing $f" >&2; done
    exit 2
  fi
  firstline() { awk 'NF { print $1; exit }' "$1"; }
  DEMO_REPO="${CREW_DEMO_REPO:-$(firstline "$DEMO_DIR/repo")}"
  DEMO_SHA=$(firstline "$DEMO_DIR/sha")
  [[ -s "$DEMO_DIR/slug" ]] && SLUG=$(firstline "$DEMO_DIR/slug") || SLUG=demo
fi

if [[ -e "$DIR" ]]; then
  [[ -e "$DIR/.git/crew-smoke" ]] || fail "$DIR exists and is not a smoke repo — refusing to delete it"
  rm -rf "$DIR" || fail "cannot remove the previous smoke repo at $DIR"
fi

# --- build the repo -----------------------------------------------------------------------------
if [[ $DEMO -eq 1 ]]; then
  git clone -q --no-checkout "$DEMO_REPO" "$DIR" || fail "cannot clone $DEMO_REPO"
  # The marker first: a checkout that fails below still leaves a repo the next run may delete.
  mkdir -p "$DIR/.git/crew-smoke"
  cd "$DIR" || exit 1
  git checkout -q -B main "$DEMO_SHA" || fail "cannot check out $DEMO_SHA from $DEMO_REPO"
  git for-each-ref --format='%(refname:short)' refs/heads | grep -vx main | xargs -r git branch -q -D
  git remote remove origin || fail "cannot remove the clone's remote"
  git config user.email crew-smoke@example.invalid
  git config user.name crew-smoke
  mkdir -p ".scratch/$SLUG" && cp -R "$DEMO_DIR/feature/." ".scratch/$SLUG/" || fail "cannot copy the feature"
  # .scratch/ is usually gitignored in the demo project, which leaves nothing to commit here.
  git add -A && { git diff --cached --quiet || git commit -qm "smoke: demo feature"; } || fail "feature commit failed"
else
  mkdir -p "$DIR" || fail "cannot create $DIR"
  cd "$DIR" || exit 1
  git init -q -b main || fail "git init failed"
  mkdir -p .git/crew-smoke
  git config user.email crew-smoke@example.invalid
  git config user.name crew-smoke
  cp -R "$FIXTURES/template/." . || fail "cannot copy the template"
  mkdir -p ".scratch/$SLUG" && cp -R "$FIXTURES/feature/." ".scratch/$SLUG/" || fail "cannot copy the feature"
  git add -A && git commit -qm "smoke: template and issue" || fail "initial commit failed"
fi

TARGET_REPO="$DIR" "$ROOT/install.sh" "$PLATFORM" --skill crew-afk >.git/crew-smoke/install.log 2>&1 \
  || fail "install.sh failed — see $DIR/.git/crew-smoke/install.log"
git add -A && git commit -qm "smoke: install crew-afk ($PLATFORM)" || fail "install commit failed"
echo "SMOKE: repo ready at $DIR ($PLATFORM)"
[[ $SETUP_ONLY -eq 1 ]] && exit 0

# --- run ----------------------------------------------------------------------------------------
# CREW_SMOKE_AFK replaces the crew-afk command (tests stub it; it then makes no CLI call).
AFK=(node .coding-crew/crew-afk/main.mjs)
[[ -n "${CREW_SMOKE_AFK:-}" ]] && AFK=("$CREW_SMOKE_AFK")
[[ $DEMO -eq 1 ]] && RECORD=1
"${AFK[@]}" doctor --platform "$PLATFORM" || fail "doctor reported a problem"

LOG=.git/crew-smoke/run.log
echo "SMOKE: running the sprint (log: $DIR/$LOG)"
"${AFK[@]}" run --platform "$PLATFORM" --feature-slug "$SLUG" "${EXTRA[@]}" >"$LOG" 2>&1
rc=$?
tail -n 40 "$LOG"

# --- check --------------------------------------------------------------------------------------
[[ $rc -eq 0 ]] || fail "crew-afk exited $rc (log: $DIR/$LOG, traces: $DIR/.scratch/$SLUG/traces/)"
if [[ $DEMO -eq 1 ]]; then
  left=$(find ".scratch/$SLUG/issues" -name '*.md' -not -path '*/done/*' 2>/dev/null | sort | tr '\n' ' ')
  [[ -z "$left" ]] || fail "issues not done: $left"
  [[ -n "$(find ".scratch/$SLUG/issues/done" -name '*.md' 2>/dev/null)" ]] || fail "no issue was closed"
  CHECK=$(mktemp -d) || fail "mktemp failed"
  git worktree add -q --detach "$CHECK" "feature/$SLUG" || fail "cannot check out feature/$SLUG"
  failed=""
  while IFS= read -r cmd || [[ -n "$cmd" ]]; do
    [[ -z "${cmd// }" || "$cmd" =~ ^[[:space:]]*# ]] && continue
    (cd "$CHECK" && bash -c "$cmd" </dev/null) >>.git/crew-smoke/check.log 2>&1 || { failed="$cmd (exit $?)"; break; }
  done <"$DEMO_DIR/check"
  git worktree remove --force "$CHECK"
  [[ -z "$failed" ]] || fail "check \`$failed\` fails on feature/$SLUG (log: $DIR/.git/crew-smoke/check.log)"
  record PASS
  echo "SMOKE: PASS ($PLATFORM, demo)"
  exit 0
fi
[[ -f ".scratch/$SLUG/issues/done/01-add-sub.md" ]] || fail "the issue was not closed"
git show "feature/$SLUG:src/math.js" | grep -q 'sub' || fail "feature/$SLUG does not define sub"
CHECK=$(mktemp -d) || fail "mktemp failed"
git worktree add -q --detach "$CHECK" "feature/$SLUG" || fail "cannot check out feature/$SLUG"
(cd "$CHECK" && node --test >/dev/null 2>&1); trc=$?
git worktree remove --force "$CHECK"
[[ $trc -eq 0 ]] || fail "node --test fails on feature/$SLUG"
echo "SMOKE: PASS ($PLATFORM)"
