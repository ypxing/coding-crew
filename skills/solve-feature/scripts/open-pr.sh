#!/usr/bin/env bash
# open-pr.sh --slug <slug> --branch <b> --title <t> --closes-file <f> --verify-line '<text>' [--draft] [--create]
# Push <b>; with --create open its PR unless an OPEN one exists, else print the `gh pr create` command.
# Prints `PR: <url>`, `PR: <url> existing`, or `PR: none` then the command as the last line; exit 1 on a
# failed push or create. An existing PR is left alone: its body and draft state may be a human's.
set -euo pipefail
die() { echo "open-pr.sh: $1" >&2; exit "${2:-1}"; }
SLUG="" BRANCH="" TITLE="" CLOSES="" VLINE="" DRAFT="" CREATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --draft) DRAFT=--draft; shift; continue ;; --create) CREATE=1; shift; continue ;;
    --*) [ $# -ge 2 ] || die "$1 needs a value" 2 ;;
  esac
  case "$1" in
    --slug) SLUG="$2" ;; --branch) BRANCH="$2" ;; --title) TITLE="$2" ;;
    --closes-file) CLOSES="$2" ;; --verify-line) VLINE="$2" ;; *) die "unexpected argument: $1" 2 ;;
  esac; shift 2
done
[ -n "$SLUG" ] && [ -n "$BRANCH" ] && [ -n "$TITLE" ] && [ -n "$VLINE" ] && [ -f "$CLOSES" ] ||
  die "usage: open-pr.sh --slug <slug> --branch <b> --title <t> --closes-file <f> --verify-line '<text>' [--draft] [--create]" 2

# address-pr-comments finds a solve-feature PR by the begin line and reads its slug from the slug line.
BODY="<!-- solve-feature:begin -->
Implemented by solve-feature (\`$SLUG\`).
Whole-feature verify: $VLINE

$(cat "$CLOSES")
<!-- solve-feature:slug $SLUG -->
<!-- solve-feature:end -->"

git push -q -u origin "$BRANCH" || die "push of $BRANCH failed"
if [ "$CREATE" = 0 ]; then
  echo "PR: none"
  echo "gh pr create${DRAFT:+ $DRAFT} --title $(printf %q "$TITLE") --body $(printf %q "$BODY")"
  exit 0
fi
pr=$(gh pr view "$BRANCH" --json number,state,url 2>/dev/null || true)
if [ "$(jq -r '.state // empty' <<<"$pr" 2>/dev/null)" = OPEN ]; then echo "PR: $(jq -r .url <<<"$pr") existing"; exit 0; fi
url=$(gh pr create $DRAFT --title "$TITLE" --body "$BODY") || die "gh pr create failed"
echo "PR: $url"
