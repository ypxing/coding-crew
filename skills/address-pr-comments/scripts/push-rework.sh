#!/usr/bin/env bash
# push-rework.sh — commit and push one rework round, behind guards.
#
# Usage: push-rework.sh --message <msg> --files <list> [--ci-workflow <file>]
#   <list> is whitespace- or comma-separated. Only those files are committed.
#
# Guards, in order:
#   1. Round cap (only with CI=true): commits carrying a `Crew-Rework: <n>` trailer made after
#      the latest `/crew-rework` PR comment by a trusted author (all of them if none); 2 or more
#      refuses.
#   2. Protected paths: PROTECTED_PATTERNS below.
#   3. Checks: solve-issue's run-checks.sh must print `CHECKS: pass`.
#   4. Commit with a `Crew-Rework: <n+1>` trailer, then a plain `git push` (never forced).
#   5. --ci-workflow: `gh workflow run <file> --ref <branch>`.
#
# A refusal posts one PR comment, adds the `needs-human` label, and exits non-zero:
#   10 round cap reached     11 protected path touched     12 checks failed
#   13 push rejected (e.g. non-fast-forward)     14 commit failed     2 usage error
# On success prints the pushed sha (and only that) on stdout; exit 0.
#
# Env: RUN_CHECKS (path to run-checks.sh), DEP_SCRIPTS, MAIN_ROOT override the sibling-skill lookup.

set -uo pipefail

# Case-insensitive extended regexes; a file matching any is protected.
PROTECTED_PATTERNS=(
  '^\.github/'
  '(^|/)\.gitlab-ci\.yml$'
  '(^|/)Jenkinsfile$'
  '(^|/)\.env'
  '(^|/|[-_.])(auth|oauth|authn|authz|deploy|deployment)([-_./]|$)'
)
ROUND_CAP=2

MESSAGE=""; FILES_RAW=""; CI_WORKFLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --message|--files|--ci-workflow)
      [ $# -ge 2 ] || { echo "Error: $1 requires a value" >&2; exit 2; }
      case "$1" in --message) MESSAGE="$2" ;; --files) FILES_RAW="$2" ;; --ci-workflow) CI_WORKFLOW="$2" ;; esac
      shift 2 ;;
    *) echo "Error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$MESSAGE" ] && [ -n "$FILES_RAW" ] || { echo "Usage: push-rework.sh --message <msg> --files <list> [--ci-workflow <file>]" >&2; exit 2; }

FILES=()
for f in $(printf '%s' "$FILES_RAW" | tr ',' ' '); do FILES+=("$f"); done

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
PR=$(gh pr view --json number -q .number 2>/dev/null || true)

refuse() { # <code> <reason>
  local code=$1 reason=$2
  echo "push-rework: refused — $reason" >&2
  if [ -n "$PR" ]; then
    gh pr comment "$PR" --body "Crew rework refused: $reason

A human needs to take a look." >/dev/null 2>&1 || true
    gh label create needs-human --force >/dev/null 2>&1 || true
    gh pr edit "$PR" --add-label needs-human >/dev/null 2>&1 || true
  fi
  exit "$code"
}

is_trusted() { # <login> — write/maintain/admin
  local nwo perm
  nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 1
  perm=$(gh api "repos/$nwo/collaborators/$1/permission" --jq .permission 2>/dev/null || true)
  case "$perm" in write|maintain|admin) return 0 ;; *) return 1 ;; esac
}

# --- 1. round cap -------------------------------------------------------------------------
ROUND=0
if [ "${CI:-}" = "true" ]; then
  since=0
  if [ -n "$PR" ]; then
    seen=" "
    while IFS=$'\t' read -r login ts; do
      [ -n "$login" ] || continue
      case "$seen" in *" $login "*) continue ;; esac
      seen="$seen$login "
      if is_trusted "$login"; then since=$ts; break; fi
    done < <(gh pr view "$PR" --json comments -q '
      [.comments[] | select(.body | test("^\\s*/crew-rework")) | {l: .author.login, t: (.createdAt | fromdateiso8601)}]
      | sort_by(.t) | reverse | .[] | [.l, .t] | @tsv' 2>/dev/null)
  fi
  for c in $(git log --format='%H' 2>/dev/null); do
    tr=$(git log -1 --format='%(trailers:key=Crew-Rework,valueonly)' "$c" | tr -d '[:space:]')
    [ -n "$tr" ] || continue
    [ "$(git log -1 --format=%ct "$c")" -gt "$since" ] && ROUND=$((ROUND + 1))
  done
  [ "$ROUND" -lt "$ROUND_CAP" ] || refuse 10 "round cap reached ($ROUND unattended rework rounds since the last trusted /crew-rework comment); comment /crew-rework to allow more"
fi

# --- 2. protected paths -------------------------------------------------------------------
touched=""
for f in "${FILES[@]}"; do
  for p in "${PROTECTED_PATTERNS[@]}"; do
    if printf '%s\n' "$f" | grep -Eiq -e "$p"; then touched="$touched $f"; break; fi
  done
done
[ -z "$touched" ] || refuse 11 "the change touches protected paths:$touched"

# --- 3. checks ----------------------------------------------------------------------------
RUN_CHECKS="${RUN_CHECKS:-$SKILL_DIR/../solve-issue/scripts/run-checks.sh}"
DEP_SCRIPTS="${DEP_SCRIPTS:-$SKILL_DIR/../dep-install/scripts}"
out=$(bash "$RUN_CHECKS" --project-root "$PROJECT_ROOT" --main-root "${MAIN_ROOT:-}" --dep-scripts "$DEP_SCRIPTS" 2>&1)
if ! printf '%s\n' "$out" | grep -qx 'CHECKS: pass'; then
  refuse 12 "checks did not pass. Tail of the output:

\`\`\`
$(printf '%s\n' "$out" | tail -40)
\`\`\`"
fi

# --- 4. commit and push -------------------------------------------------------------------
git add -- "${FILES[@]}" >&2 || refuse 14 "could not stage the given files"
git commit -q -m "$MESSAGE

Crew-Rework: $((ROUND + 1))" -- "${FILES[@]}" >&2 || refuse 14 "commit failed"
if ! perr=$(git push origin "$BRANCH" 2>&1); then
  refuse 13 "push rejected (never forced): $(printf '%s\n' "$perr" | tail -5)"
fi

# --- 5. CI re-trigger ---------------------------------------------------------------------
if [ -n "$CI_WORKFLOW" ]; then
  gh workflow run "$CI_WORKFLOW" --ref "$BRANCH" >&2 || echo "push-rework: warning: could not trigger $CI_WORKFLOW" >&2
fi

git rev-parse HEAD
