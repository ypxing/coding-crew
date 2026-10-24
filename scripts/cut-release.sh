#!/usr/bin/env bash
# cut-release.sh — tag and push a milestone release once its checks pass.
# Usage: scripts/cut-release.sh [--dry-run] (--demo-smoke <log> | --no-demo-smoke "<reason>")
# The version is read back from CHANGELOG.md's first "## [X.Y.Z]" heading, so it is decided in one
# place. A demo smoke log must hold `SMOKE: PASS (<platform>, demo)` and the `crew-afk-commit:` it ran
# at, from a clean checkout with nothing changed since but CHANGELOG.md, RESULTS.md and the two files that pin
# coding-crew's tag: every `uses: ypxing/coding-crew/…@<ref>` in the reusable workflow and the caller template
# must read the tag being cut.
# --dry-run runs every check and prints what would be tagged/pushed, without doing either.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

USAGE="Usage: $0 [--dry-run] (--demo-smoke <log> | --no-demo-smoke \"<reason>\")"
DRY_RUN=0 DEMO_LOG="" NO_DEMO="" NO_DEMO_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --demo-smoke) [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; DEMO_LOG="$2"; shift 2 ;;
    --no-demo-smoke) [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; NO_DEMO="$2"; NO_DEMO_SET=1; shift 2 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done

if [[ -n "$DEMO_LOG" && "$NO_DEMO_SET" -eq 1 ]]; then
  echo "Error: --demo-smoke and --no-demo-smoke exclude each other. $USAGE" >&2; exit 2
elif [[ -z "$DEMO_LOG" && "$NO_DEMO_SET" -eq 0 ]]; then
  echo "Error: no demo smoke — pass --demo-smoke <log> (scripts/smoke-crew-afk.sh <platform> output)" \
       "or --no-demo-smoke \"<reason>\"." >&2
  exit 2
elif [[ "$NO_DEMO_SET" -eq 1 && -z "${NO_DEMO// }" ]]; then
  echo "Error: --no-demo-smoke needs a reason." >&2; exit 2
fi

[[ -z "$(git status --porcelain)" ]] || {
  echo "Error: working tree not clean — commit (including the CHANGELOG.md entry) before releasing." >&2
  exit 1
}

BRANCH=$(git rev-parse --abbrev-ref HEAD)
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
[[ -n "$UPSTREAM" ]] || { echo "Error: '$BRANCH' has no upstream to push to." >&2; exit 1; }
REMOTE="${UPSTREAM%%/*}"

NEXT=$(awk '/^## \[[0-9]/{print; exit}' CHANGELOG.md | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')
[[ "$NEXT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Error: CHANGELOG.md's top heading isn't a '## [X.Y.Z]' version. Add this release's entry first." >&2
  exit 1
}
TAG="v$NEXT"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Error: $TAG already exists." >&2; exit 1; }

# A repo's caller and the reusable workflow name coding-crew by a literal tag, so the release that ships them
# must be the one they name; the release commit bumps them with the CHANGELOG heading.
PINNED_FILES=(.github/workflows/crew-solve-feature.yml skills/setup-coding-crew/hosts/github-actions.yml)
for f in "${PINNED_FILES[@]}"; do
  refs=$(sed -nE 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*ypxing\/coding-crew\/[^@[:space:]]+@([^[:space:]#]+).*/\2/p' "$f" 2>/dev/null || true)
  [[ -n "$refs" ]] || { echo "Error: $f names no ypxing/coding-crew/…@<ref> on a uses: line." >&2; exit 1; }
  for ref in $refs; do
    [[ "$ref" == "$TAG" ]] || {
      echo "Error: $f uses coding-crew @$ref, not @$TAG: bump it in the release commit, with the CHANGELOG heading." >&2
      exit 1
    }
  done
done

PREV_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)
if [[ -n "$PREV_TAG" ]]; then
  IFS=. read -r pM pm pp <<<"${PREV_TAG#v}"
  IFS=. read -r nM nm np <<<"$NEXT"
  if ! { [[ "$nM" -gt "$pM" ]] ||
         { [[ "$nM" -eq "$pM" ]] && [[ "$nm" -gt "$pm" ]]; } ||
         { [[ "$nM" -eq "$pM" ]] && [[ "$nm" -eq "$pm" ]] && [[ "$np" -gt "$pp" ]]; }; }; then
    echo "Error: CHANGELOG.md's top version $NEXT is not greater than the last release $PREV_TAG." >&2
    exit 1
  fi
fi

echo "Releasing $TAG (previous: ${PREV_TAG:-none})"

if [[ -n "$DEMO_LOG" ]]; then
  [[ -f "$DEMO_LOG" ]] || { echo "Error: demo smoke log $DEMO_LOG not found." >&2; exit 1; }
  grep -q '^SMOKE: PASS' "$DEMO_LOG" || {
    echo "Error: $DEMO_LOG has no 'SMOKE: PASS' line — the demo smoke did not pass." >&2; exit 1
  }
  grep -Eq '^SMOKE: PASS \([a-z]+, demo\)$' "$DEMO_LOG" || {
    echo "Error: $DEMO_LOG is not a demo run's — its PASS line lacks ', demo)'. Run scripts/smoke-crew-afk.sh <platform>." >&2
    exit 1
  }
  LOG_COMMIT=$(sed -n 's/^crew-afk-commit: *//p' "$DEMO_LOG" | tail -n 1)
  [[ -n "$LOG_COMMIT" ]] || { echo "Error: $DEMO_LOG records no 'crew-afk-commit:' line — re-run the demo smoke." >&2; exit 1; }
  [[ "$LOG_COMMIT" != *-dirty ]] || {
    echo "Error: $DEMO_LOG ran on uncommitted changes (${LOG_COMMIT%-dirty}-dirty) — commit, then re-run the demo smoke." >&2
    exit 1
  }
  git merge-base --is-ancestor "$LOG_COMMIT" HEAD 2>/dev/null || {
    echo "Error: $DEMO_LOG ran at $LOG_COMMIT, which HEAD does not descend from — re-run the demo smoke." >&2
    exit 1
  }
  SINCE=$(git diff --name-only "$LOG_COMMIT" HEAD -- . ':(exclude)CHANGELOG.md' ':(exclude)scripts/smoke-crew-afk/RESULTS.md' \
    "${PINNED_FILES[@]/#/:(exclude)}")
  [[ -z "$SINCE" ]] || {
    echo "Error: $DEMO_LOG ran at ${LOG_COMMIT:0:12}; these files changed since — re-run the demo smoke:" >&2
    printf '  %s\n' $SINCE >&2
    exit 1
  }
  echo "Demo smoke: PASS at ${LOG_COMMIT:0:12} ($DEMO_LOG)"
else
  echo "Demo smoke: skipped — $NO_DEMO"
fi

SUBJECT=$(git log -1 --format=%s)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run — would tag HEAD as $TAG (\"$SUBJECT\") and push $BRANCH + $TAG to $REMOTE."
  exit 0
fi

git tag -a "$TAG" -m "$SUBJECT"
git push "$REMOTE" "$BRANCH" "$TAG"

echo "Pushed $TAG. .github/workflows/release.yml will publish the GitHub Release from CHANGELOG.md's [$NEXT] section."
