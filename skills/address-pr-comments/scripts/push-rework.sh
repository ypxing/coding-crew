#!/usr/bin/env bash
# push-rework.sh — commit and push one rework round, behind guards; prints the pushed sha.
# Usage: push-rework.sh --message <msg> --files <list> [--ci-workflow <file>]  (<list>: space or comma separated)
# Guards: a round cap (CI=true only: 2 `Crew-Rework:` commits since the latest trusted `/crew-rework`
# comment), PROTECTED_PATTERNS, run-checks.sh's `CHECKS: pass`; then a `Crew-Rework: <n+1>` commit, plain push.
# A refusal comments on the PR, labels it `needs-human` and exits 10 round cap, 11 protected path,
# 12 checks failed, 13 push rejected, 14 commit failed; 2 is a usage error.

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

touched=""
for f in "${FILES[@]}"; do
  for p in "${PROTECTED_PATTERNS[@]}"; do
    if grep -Eiq -e "$p" <<<"$f"; then touched="$touched $f"; break; fi
  done
done
[ -z "$touched" ] || refuse 11 "the change touches protected paths:$touched"

RUN_CHECKS="${RUN_CHECKS:-$SKILL_DIR/../solve-issue/scripts/run-checks.sh}"
DEP_SCRIPTS="${DEP_SCRIPTS:-$SKILL_DIR/../dep-install/scripts}"
out=$(bash "$RUN_CHECKS" --project-root "$PROJECT_ROOT" --main-root "${MAIN_ROOT:-}" --dep-scripts "$DEP_SCRIPTS" 2>&1)
if ! grep -qx 'CHECKS: pass' <<<"$out"; then
  refuse 12 "checks did not pass. Tail of the output:

\`\`\`
$(printf '%s\n' "$out" | tail -40)
\`\`\`"
fi

git add -- "${FILES[@]}" >&2 || refuse 14 "could not stage the given files"
git commit -q -m "$MESSAGE

Crew-Rework: $((ROUND + 1))" -- "${FILES[@]}" >&2 || refuse 14 "commit failed"
if ! perr=$(git push origin "$BRANCH" 2>&1); then
  refuse 13 "push rejected (never forced): $(printf '%s\n' "$perr" | tail -5)"
fi

if [ -n "$CI_WORKFLOW" ]; then
  gh workflow run "$CI_WORKFLOW" --ref "$BRANCH" >&2 || echo "push-rework: warning: could not trigger $CI_WORKFLOW" >&2
fi

git rev-parse HEAD
