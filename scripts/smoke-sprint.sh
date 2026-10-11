#!/usr/bin/env bash
set -uo pipefail

# smoke-sprint.sh — run one real crew-afk sprint end to end on one platform, from a fresh repo.
# Usage: scripts/smoke-sprint.sh <platform> [--demo] [--dir <path>] [--setup-only] [-- <crew-afk run args>...]
# Prints `SMOKE: PASS (<platform>)` (`, demo)` under --demo, the only line cut-release.sh accepts) or
# `SMOKE: FAIL: <why>`, plus `crew-afk-version:`/`crew-afk-commit:` lines cut-release.sh reads back.
# --demo uses the pinned project in scripts/smoke-sprint/demo/ and appends a RESULTS.md row.
# Maintainer-only: ships to no consumer. A real run calls the platform's CLI and costs money.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PLATFORMS=()
while IFS= read -r _p; do PLATFORMS+=("${_p%$'\r'}"); done < <(jq -r 'keys_unsorted[]' "$ROOT/orchestrator/platforms.json")
FIXTURES="$SCRIPT_DIR/smoke-sprint"
SLUG=subtract
RECORD=0

usage() { echo "usage: $0 <$(IFS='|'; echo "${PLATFORMS[*]}")> [--demo] [--dir <path>] [--setup-only] [-- <crew-afk run args>...]" >&2; exit 2; }
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
  # Folded as review-rollup.mjs folds them (latest per branch), so a repeated finding counts once.
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
COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || COMMIT=unknown
[[ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]] || COMMIT="$COMMIT-dirty"
echo "crew-afk-commit: $COMMIT"

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
  # Retried: on macOS CI a lone rm -rf can fail with "Directory not empty" under .git while
  # something still writes there; a later pass succeeds.
  for _ in 1 2 3 4 5; do rm -rf "$DIR" 2>/dev/null && break; sleep 1; done
  [[ ! -e "$DIR" ]] || rm -rf "$DIR" || fail "cannot remove the previous smoke repo at $DIR"
fi

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
