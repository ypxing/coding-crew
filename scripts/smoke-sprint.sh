#!/usr/bin/env bash
set -uo pipefail

# smoke-sprint.sh — run one real crew-afk sprint end to end on one platform, from a fresh repo.
#
# Usage: scripts/smoke-sprint.sh <claude|copilot|pi|codex> [--dir <path>] [--setup-only] [-- <crew-afk run args>...]
#
# Builds a throwaway git repo from scripts/smoke-sprint/template/ (a tiny Node project, `npm test`
# = `node --test`) with one ready issue from scripts/smoke-sprint/feature/ (`.scratch/subtract/`:
# add `sub()`), installs crew-afk for <platform> from this checkout, runs `doctor`, then
# `crew-afk run --feature-slug subtract`, and checks the outcome:
#   - crew-afk exited 0
#   - the issue is in `.scratch/subtract/issues/done/`
#   - `feature/subtract` exports `sub` and its `node --test` passes
# Prints `SMOKE: PASS` / `SMOKE: FAIL: <why>`; exit 0 / 1, 2 on a usage error.
#
# Repeatable: the repo is rebuilt from the template on every run, so no branch, sprint state or
# dev-commands cache from an earlier run leaks in. The directory (default
# ${TMPDIR:-/tmp}/crew-smoke-<platform>) is deleted first only when it is an earlier smoke repo
# (`.git/crew-smoke` marker); any other existing path is refused. The crew-afk log is kept at
# <dir>/.git/crew-smoke/run.log. --setup-only stops after install (no CLI call, no API cost).
#
# Maintainer-only: ships to no consumer. A real run calls the platform's CLI and costs money.

PLATFORMS=(claude copilot pi codex)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FIXTURES="$SCRIPT_DIR/smoke-sprint"
SLUG=subtract

usage() { echo "usage: $0 <claude|copilot|pi|codex> [--dir <path>] [--setup-only] [-- <crew-afk run args>...]" >&2; exit 2; }
fail() { echo "SMOKE: FAIL: $*"; exit 1; }

PLATFORM="${1:-}"
[[ " ${PLATFORMS[*]} " == *" $PLATFORM "* && -n "$PLATFORM" ]] || usage
shift
DIR="" SETUP_ONLY=0 EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) [[ $# -ge 2 ]] || usage; DIR="$2"; shift 2 ;;
    --setup-only) SETUP_ONLY=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    *) usage ;;
  esac
done
DIR="${DIR:-${TMPDIR:-/tmp}/crew-smoke-$PLATFORM}"

if [[ -e "$DIR" ]]; then
  [[ -e "$DIR/.git/crew-smoke" ]] || fail "$DIR exists and is not a smoke repo — refusing to delete it"
  rm -rf "$DIR" || fail "cannot remove the previous smoke repo at $DIR"
fi

# --- build the repo -----------------------------------------------------------------------------
mkdir -p "$DIR" || fail "cannot create $DIR"
cd "$DIR" || exit 1
git init -q -b main || fail "git init failed"
mkdir -p .git/crew-smoke
git config user.email crew-smoke@example.invalid
git config user.name crew-smoke
cp -R "$FIXTURES/template/." . || fail "cannot copy the template"
mkdir -p ".scratch/$SLUG" && cp -R "$FIXTURES/feature/." ".scratch/$SLUG/" || fail "cannot copy the feature"
git add -A && git commit -qm "smoke: template and issue" || fail "initial commit failed"

TARGET_REPO="$DIR" "$ROOT/install.sh" "$PLATFORM" --skill crew-afk >.git/crew-smoke/install.log 2>&1 \
  || fail "install.sh failed — see $DIR/.git/crew-smoke/install.log"
git add -A && git commit -qm "smoke: install crew-afk ($PLATFORM)" || fail "install commit failed"
echo "SMOKE: repo ready at $DIR ($PLATFORM)"
[[ $SETUP_ONLY -eq 1 ]] && exit 0

# --- run ----------------------------------------------------------------------------------------
MAIN=.coding-crew/crew-afk/main.mjs
node "$MAIN" doctor --platform "$PLATFORM" || fail "doctor reported a problem"

LOG=.git/crew-smoke/run.log
echo "SMOKE: running the sprint (log: $DIR/$LOG)"
node "$MAIN" run --platform "$PLATFORM" --feature-slug "$SLUG" "${EXTRA[@]}" >"$LOG" 2>&1
rc=$?
tail -n 40 "$LOG"

# --- check --------------------------------------------------------------------------------------
[[ $rc -eq 0 ]] || fail "crew-afk exited $rc (log: $DIR/$LOG, traces: $DIR/.scratch/$SLUG/traces/)"
[[ -f ".scratch/$SLUG/issues/done/01-add-sub.md" ]] || fail "the issue was not closed"
git show "feature/$SLUG:src/math.js" | grep -q 'sub' || fail "feature/$SLUG does not define sub"
CHECK=$(mktemp -d) || fail "mktemp failed"
git worktree add -q --detach "$CHECK" "feature/$SLUG" || fail "cannot check out feature/$SLUG"
(cd "$CHECK" && node --test >/dev/null 2>&1); trc=$?
git worktree remove --force "$CHECK"
[[ $trc -eq 0 ]] || fail "node --test fails on feature/$SLUG"
echo "SMOKE: PASS ($PLATFORM)"
