#!/usr/bin/env bash
# cut-release.sh — mechanize the deterministic parts of releasing this repo.
#
# Why this exists: "commit, tag, push, release" on this repo had no tooling behind it, so doing
# it meant rediscovering the whole procedure from scratch every time — grep CHANGELOG.md for the
# versioning convention, compute the next semver number from git tags, eyeball registry.json for
# entries that need a version bump (the exact check tests/registry-version-bump.bats already
# automates), hand-craft `git tag -a` with the right subject, and remember to push both the
# branch and the tag. None of that is judgement, just "read git history" or "run the existing
# test" — so a release should cost one command, not a dozen exploratory reads and greps.
#
# Usage: scripts/cut-release.sh [--dry-run]
#
# Preconditions this enforces (fails fast, does not guess):
#   - working tree clean, HEAD's branch has an upstream to push to
#   - CHANGELOG.md's first "## [X.Y.Z]" heading names the version this HEAD ships as — you still
#     write that entry; this script only reads the version number back out of it, so there is
#     exactly one place the version is decided, not two that can disagree
#   - that version is greater than the nearest previous release tag
#   - tests/registry-version-bump.bats passes against that previous tag (install.sh --update
#     silently skips any agent/skill whose shipped files changed without its own version bumping
#     — see that test for the full story)
#   - HEAD is not already tagged
#
# --dry-run runs every check above and prints what would be tagged/pushed, without doing either.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
  esac
done

[[ -z "$(git status --porcelain)" ]] || {
  echo "Error: working tree not clean — commit (including the CHANGELOG.md/registry.json bumps) before releasing." >&2
  exit 1
}

BRANCH=$(git rev-parse --abbrev-ref HEAD)
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
[[ -n "$UPSTREAM" ]] || { echo "Error: '$BRANCH' has no upstream to push to." >&2; exit 1; }
REMOTE="${UPSTREAM%%/*}"

NEXT=$(awk '/^## \[/{print; exit}' CHANGELOG.md | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/')
[[ "$NEXT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Error: CHANGELOG.md's top heading isn't a '## [X.Y.Z]' version. Add this release's entry first." >&2
  exit 1
}
TAG="v$NEXT"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Error: $TAG already exists." >&2; exit 1; }

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

if command -v bats >/dev/null 2>&1; then
  echo "Checking registry.json version bumps against ${PREV_TAG:-<none>} ..."
  bats tests/registry-version-bump.bats
else
  echo "Warning: bats not found on PATH — skipping the registry.json version-bump check." \
       "Run 'bats tests/registry-version-bump.bats' yourself before trusting this release." >&2
fi

SUBJECT=$(git log -1 --format=%s)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run — would tag HEAD as $TAG (\"$SUBJECT\") and push $BRANCH + $TAG to $REMOTE."
  exit 0
fi

git tag -a "$TAG" -m "$SUBJECT"
git push "$REMOTE" "$BRANCH" "$TAG"

echo "Pushed $TAG. .github/workflows/release.yml will publish the GitHub Release from CHANGELOG.md's [$NEXT] section."
