#!/usr/bin/env bash
set -euo pipefail

# open-pr.sh — push the feature branch and create, or update, its pull request.
#
# Usage: open-pr.sh [--closes-file <file>]
#   FEATURE_BRANCH and FEATURE_SLUG come from the environment (the orchestrator's childEnv).
#   --closes-file holds the tracker's closing lines (`Closes #n`), one per line; absent or
#   empty, the PR closes nothing.
#
# The body's crew-afk block — between the two markers below — is the only part this writes:
# a new PR gets just that block, and an open one has it replaced (or appended), so what a
# human wrote around it survives every re-run. The PR is opened against the repo's default
# branch, the only base GitHub honours `Closes #n` for.
#
# The push is a plain one. A rejected (non-fast-forward) push fails this script rather than
# forcing over the remote; the caller reports it.
#
# Also adds the `crew-rework` label (created if missing) to the PR, new or updated.
#
# Prints `PR: <url>` on success.

CLOSES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --closes-file) CLOSES_FILE="${2:-}"; shift 2 ;;
    *) echo "open-pr.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${FEATURE_BRANCH:?FEATURE_BRANCH is not set}"
: "${FEATURE_SLUG:?FEATURE_SLUG is not set}"
MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$MAIN_ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }

BEGIN_MARK="<!-- crew-afk:begin -->"
END_MARK="<!-- crew-afk:end -->"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

{
  echo "$BEGIN_MARK"
  echo "Implemented by a crew-afk sprint (\`$FEATURE_SLUG\`)."
  if [ -n "$CLOSES_FILE" ] && [ -s "$CLOSES_FILE" ]; then
    echo ""
    cat "$CLOSES_FILE"
  fi
  echo "$END_MARK"
} > "$TMP/block.md"

if ! push_out=$(git push -u origin "$FEATURE_BRANCH" 2>&1); then
  echo "open-pr.sh: git push failed: $push_out" >&2
  _trace --level error PR "branch=$FEATURE_BRANCH success=false reason=push"
  exit 1
fi

# `gh pr view <branch>` also finds a merged or closed PR for the branch; only an open one is
# updated, anything else gets a new PR.
existing=$(gh pr view "$FEATURE_BRANCH" --json url,state,body 2>/dev/null || true)
state=$(printf '%s' "$existing" | jq -r '.state // empty' 2>/dev/null || true)

if [ "$state" = "OPEN" ]; then
  # CRLF → LF: GitHub keeps a body edited in its web UI with \r\n (and Windows' jq writes
  # \r\n), and a marker line ending in \r never equals the marker, so the block would stay stale.
  printf '%s' "$existing" | jq -r '.body // ""' | tr -d '\r' > "$TMP/old.md"
  if grep -qF "$BEGIN_MARK" "$TMP/old.md"; then
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v blockfile="$TMP/block.md" '
      $0 == begin { while ((getline line < blockfile) > 0) print line; skip = 1; next }
      $0 == end   { skip = 0; next }
      !skip       { print }
    ' "$TMP/old.md" > "$TMP/body.md"
  else
    { cat "$TMP/old.md"; [ -s "$TMP/old.md" ] && printf '\n\n'; cat "$TMP/block.md"; } > "$TMP/body.md"
  fi
  gh pr edit "$FEATURE_BRANCH" --body-file "$TMP/body.md" >/dev/null
  url=$(printf '%s' "$existing" | jq -r '.url')
else
  url=$(gh pr create --head "$FEATURE_BRANCH" --title "$FEATURE_SLUG" --body-file "$TMP/block.md" | tail -1)
fi

# The label is what arms the crew-rework GitHub Action; failing to add it never fails the PR.
gh label create crew-rework --force --description "Let the crew-rework workflow address review comments" >/dev/null 2>&1 || true
gh pr edit "$FEATURE_BRANCH" --add-label crew-rework >/dev/null 2>&1 || true

_trace PR "branch=$FEATURE_BRANCH url=$url"
echo "PR: $url"
