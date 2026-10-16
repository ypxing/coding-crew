#!/usr/bin/env bash
set -uo pipefail

# smoke-crew-afk.sh — the release smoke: one real crew-afk run on the pinned demo repo, on one platform.
# Usage: scripts/smoke-crew-afk.sh <platform>
# Clones the demo repo (scripts/smoke-crew-afk/demo/{repo,sha,slug,check}, feature/) into $TMPDIR, installs every
# skill at project level kept out of git, dispatches `crew-afk.sh dispatch <slug> --to local -- <the platform's
# headless launch command>` (no host agent runs here to supply one), waits for the
# run with `crew-afk.sh wait <slug>` and requires `ready pr=<n>`, then runs demo/check in the run's worktree. Appends one RESULTS.md row, closes
# the PR and deletes its branch on a pass, and prints `crew-afk-commit: <sha>[-dirty]` and
# `SMOKE: PASS (<platform>, demo)` — the lines cut-release.sh reads back — or `SMOKE: FAIL: <why>`.
# Maintainer-only: ships to no consumer. A real run calls the platform's CLI and the demo repo's GitHub, and
# costs money. CREW_SMOKE_DISPATCH replaces the dispatch command and CREW_DEMO_DIR the demo dir (tests).

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEMO_DIR="${CREW_DEMO_DIR:-$SCRIPT_DIR/smoke-crew-afk/demo}"
RESULTS="${CREW_SMOKE_RESULTS:-$SCRIPT_DIR/smoke-crew-afk/RESULTS.md}"
PLATFORMS=$(jq -r 'keys_unsorted | join("|")' "$ROOT/platforms.json" | tr -d '\r')

PLATFORM="${1:-}"
[[ $# -eq 1 && "|$PLATFORMS|" == *"|$PLATFORM|"* ]] || { echo "usage: $0 <$PLATFORMS>" >&2; exit 2; }

RECORD=0 WT="" PR="" COST='?'
# One results row once the run was dispatched: its cost from crew-afk.sh wait's line (`cost=$<n>`, when the
# platform's command ends the log with a JSON result carrying it: claude's does), and its finding count from the last review solve-feature saved (a re-review after fixes overwrites
# the first one's report).
record() {
  [[ $RECORD -eq 1 ]] || return 0
  RECORD=0
  local findings
  findings=$(jq '.findings // [] | length' "$WT/.solve-feature/pr-$PR.review.json" 2>/dev/null) || findings='?'
  echo "| $SHORT | $(date -u +%Y-%m-%d) | $PLATFORM | $1 | $COST | ${findings:-?} |" >>"$RESULTS" ||
    echo "SMOKE: warning: cannot append to $RESULTS" >&2
}
fail() { record FAIL; echo "SMOKE: FAIL: $*"; exit 1; }

COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || COMMIT=unknown
SHORT=${COMMIT:0:12}
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then COMMIT="$COMMIT-dirty" SHORT="$SHORT-dirty"; fi
echo "crew-afk-commit: $COMMIT"

for f in repo sha slug check feature; do [[ -e "$DEMO_DIR/$f" ]] || { echo "smoke-crew-afk: missing $DEMO_DIR/$f" >&2; exit 2; }; done
firstline() { awk 'NF { print $1; exit }' "$1"; }
DEMO_REPO=$(firstline "$DEMO_DIR/repo") PIN=$(firstline "$DEMO_DIR/sha") SLUG=$(firstline "$DEMO_DIR/slug")
BRANCH="feature/$SLUG"
# What a host agent on each platform would pass crew-afk after `--` for a local run: unattended, permission prompts off.
case "$PLATFORM" in
  claude) LAUNCH=(claude -p "/solve-feature $SLUG" --output-format json --dangerously-skip-permissions) ;;
  # --allow-all, not --allow-all-tools: the skill's scripts are outside the worktree, and an unattended run's path
  # check has no one to approve it.
  copilot) LAUNCH=(copilot -p "Use the solve-feature skill on $SLUG" --allow-all) ;;
  codex) LAUNCH=(codex exec --dangerously-bypass-approvals-and-sandbox "Use the solve-feature skill on $SLUG") ;;
  pi) LAUNCH=(pi -p "/skill:solve-feature $SLUG") ;;
  *) echo "smoke-crew-afk: no launch command for $PLATFORM" >&2; exit 2 ;;
esac

DIR="${TMPDIR:-/tmp}/crew-smoke-$PLATFORM"
if [[ -e "$DIR" ]]; then
  [[ -e "$DIR/.git/crew-smoke" ]] || fail "$DIR exists and is not a smoke repo — refusing to delete it"
  # Retried: on macOS a lone rm -rf can fail with "Directory not empty" while something still writes there.
  for _ in 1 2 3 4 5; do rm -rf "$DIR" 2>/dev/null && break; sleep 1; done
  [[ ! -e "$DIR" ]] || fail "cannot remove the previous smoke repo at $DIR"
fi
# The run's worktree, as crew-afk lays it out beside the checkout: the last run's belonged to the repo just removed.
rm -rf "$DIR-worktrees/$SLUG"

git clone -q "$DEMO_REPO" "$DIR" || fail "cannot clone $DEMO_REPO"
# The marker first: a run that fails below still leaves a repo the next run may delete.
mkdir -p "$DIR/.git/crew-smoke"
cd "$DIR" || exit 1
git config user.email crew-smoke@example.invalid
git config user.name crew-smoke

# The previous run's PR and branch: solve-feature would reuse them instead of starting from the pin.
OPEN=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[].number') || fail "gh pr list failed (see above)"
for n in $OPEN; do
  gh pr close "$n" >/dev/null || fail "cannot close PR $n from $BRANCH"
done
gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
git fetch -q --prune origin || fail "git fetch origin failed"
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT=${DEFAULT:-main}
# solve-feature branches from origin/<default>, so the pin is only what runs if the default branch is at it.
HEAD_SHA=$(git rev-parse "origin/$DEFAULT" 2>/dev/null)
[[ "$HEAD_SHA" == "$PIN" ]] || fail "demo repo moved: origin/$DEFAULT is $HEAD_SHA, pinned $PIN"

"$ROOT/install.sh" "$PLATFORM" --project "$DIR" >.git/crew-smoke/install.log 2>&1 ||
  fail "install.sh failed — see $DIR/.git/crew-smoke/install.log"
# A host resolves a user-level skill ahead of a project one, so the run would test a stale copy, not HEAD.
! grep -q '^WARNING: user-level copies exist' .git/crew-smoke/install.log ||
  fail "user-level skills shadow the project install (see $DIR/.git/crew-smoke/install.log)"
SKILLS=$(jq -r --arg p "$PLATFORM" '.[$p].projectSkills' "$ROOT/platforms.json" | tr -d '\r')
# Installed, never committed: excluded here, and linked into every worktree through .worktreeinclude.
printf '%s\n' .coding-crew/lib .coding-crew/manifest.json "$SKILLS" >.worktreeinclude
printf '%s\n' .coding-crew/lib .coding-crew/manifest.json "$SKILLS" .worktreeinclude .scratch/ >>.git/info/exclude
# The local tracker reads the feature from the main checkout.
mkdir -p ".scratch/$SLUG" && cp -R "$DEMO_DIR/feature/." ".scratch/$SLUG/" || fail "cannot copy the feature"
DIRTY=$(git status --porcelain)
[[ -z "$DIRTY" ]] || fail "the install left the demo repo dirty, which solve-feature refuses: $DIRTY"
echo "SMOKE: repo ready at $DIR ($PLATFORM)"

DISPATCH=(bash "$SKILLS/crew-afk/scripts/crew-afk.sh")
[[ -n "${CREW_SMOKE_DISPATCH:-}" ]] && DISPATCH=("$CREW_SMOKE_DISPATCH")
OUT=$("${DISPATCH[@]}" dispatch "$SLUG" --to local -- "${LAUNCH[@]}") || fail "crew-afk dispatch exited $?: $OUT"
echo "$OUT"
WT=$(sed -n 's/^worktree=//p' <<<"$OUT")
[[ -n "$WT" ]] || fail "crew-afk dispatch printed no worktree="
RECORD=1
echo "SMOKE: waiting for the run (log: $WT/.solve-feature/run.log)"
LINE=$("${DISPATCH[@]}" wait "$SLUG") || fail "crew-afk wait exited $?: $LINE"
echo "$LINE"
[[ "$LINE" =~ \ cost=(\$[0-9.]+) ]] && COST="${BASH_REMATCH[1]}"

OUTCOME=$(head -n 1 "$WT/.solve-feature/outcome" 2>/dev/null)
[[ "$OUTCOME" =~ pr=([0-9]+) ]] && PR="${BASH_REMATCH[1]}"
[[ "$OUTCOME" == "ready pr=$PR" && -n "$PR" ]] ||
  fail "the run ended '${OUTCOME:-without an outcome}', not ready pr=<n> (log: $WT/.solve-feature/run.log)"

while IFS= read -r cmd || [[ -n "$cmd" ]]; do
  [[ -z "${cmd// }" || "$cmd" =~ ^[[:space:]]*# ]] && continue
  (cd "$WT" && bash -c "$cmd" </dev/null) >>.git/crew-smoke/check.log 2>&1 ||
    fail "check \`$cmd\` (exit $?) fails in $WT (log: $DIR/.git/crew-smoke/check.log)"
done <"$DEMO_DIR/check"

record PASS
gh pr close "$PR" >/dev/null || echo "SMOKE: warning: cannot close PR $PR" >&2
gh api -X DELETE "repos/{owner}/{repo}/git/refs/heads/$BRANCH" >/dev/null ||
  echo "SMOKE: warning: cannot delete $BRANCH" >&2
echo "SMOKE: PASS ($PLATFORM, demo)"
