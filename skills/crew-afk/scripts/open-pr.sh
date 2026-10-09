#!/usr/bin/env bash
set -euo pipefail

# open-pr.sh — push the feature branch and create, or update, its pull request.
#
# Usage: open-pr.sh [--closes-file <file>] [--body-file <file>] [--title <title>] [--draft]
#                   [--note-file <file>] [--no-push] [--draft-marker <line>]
#   FEATURE_BRANCH and FEATURE_SLUG come from the environment (the orchestrator's childEnv).
#   --closes-file holds the tracker's closing lines (`Closes #n`), one per line; absent or
#   empty, the PR closes nothing.
#   --body-file holds the body for a reviewer (pipeline/pr-body.mjs: write-pr's Why, What
#   changes, Risk and Tested, else the checks line alone); it opens the block, above the closing lines.
#   --title is the PR's title (the writer's, else the PRD's); default the slug. An open PR keeps
#   a title a human gave it — one other than the slug this script used to default to.
#
#   --draft: the run did not finish green. A new PR is created as a draft, an open ready one is
#   converted (`gh pr ready --undo`); without it an open draft is marked ready (`gh pr ready`).
#   A failed conversion is reported as `PR-STATE-FAILED: <why>` and never fails this script.
#   --note-file holds the not-green text (blocked issues, reason) for the crew-afk block.
#   --no-push: push nothing, create nothing and edit no body — only an open PR's draft state is
#   set. For a red merged branch: the PR a green run opened must not stay ready.
#   --draft-marker (with --no-push): the one body edit it makes — the open PR's block gets this
#   `<!-- crew-afk:draft <kinds> -->` line in place of its own (or added before its end marker),
#   so a marker an earlier run wrote (say, `findings` alone) does not outlive the red branch.
#
# The body's crew-afk block — between the two markers below — is the only part this writes:
# a new PR gets just that block, and an open one has it replaced (or appended), so what a
# human wrote around it survives every re-run. The PR is opened against the repo's default
# branch, the only base GitHub honours `Closes #n` for.
#
# The push is a plain one. A rejected (non-fast-forward) push fails this script rather than
# forcing over the remote; the caller reports it.
#
# Prints `PR: <url>` on success, then `PR-STATE: draft|ready` (and `PR-STATE-FAILED: <why>`).

CLOSES_FILE=""
BODY_FILE=""
TITLE=""
DRAFT=0
NOTE_FILE=""
NO_PUSH=0
DRAFT_MARKER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --closes-file) CLOSES_FILE="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --draft) DRAFT=1; shift ;;
    --note-file) NOTE_FILE="${2:-}"; shift 2 ;;
    --no-push) NO_PUSH=1; shift ;;
    --draft-marker) DRAFT_MARKER="${2:-}"; shift 2 ;;
    *) echo "open-pr.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${FEATURE_BRANCH:?FEATURE_BRANCH is not set}"
: "${FEATURE_SLUG:?FEATURE_SLUG is not set}"
MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$MAIN_ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"} "$@" 2>/dev/null || true; return 0; }

BEGIN_MARK="<!-- crew-afk:begin -->"
END_MARK="<!-- crew-afk:end -->"
# Names the sprint the PR belongs to: the head branch's name (afk.branchPrefix, --jira) no longer
# says which .scratch/<slug>/ it is, so address-pr-comments reads the slug from here.
SLUG_MARK="<!-- crew-afk:slug $FEATURE_SLUG -->"

state_failed=""
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

{
  echo "$BEGIN_MARK"
  if [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ]; then
    # A marker line inside the body would end the block early on the next re-run.
    tr -d '\r' < "$BODY_FILE" | grep -vxF -e "$BEGIN_MARK" -e "$END_MARK" || true
    echo ""
    echo "---"
    echo ""
  fi
  echo "Implemented by a crew-afk sprint (\`$FEATURE_SLUG\`)."
  if [ -n "$NOTE_FILE" ] && [ -s "$NOTE_FILE" ]; then
    echo ""
    tr -d '\r' < "$NOTE_FILE" | grep -vxF -e "$BEGIN_MARK" -e "$END_MARK" || true
  fi
  if [ -n "$CLOSES_FILE" ] && [ -s "$CLOSES_FILE" ]; then
    echo ""
    cat "$CLOSES_FILE"
  fi
  echo "$SLUG_MARK"
  echo "$END_MARK"
} > "$TMP/block.md"

if [ "$NO_PUSH" = 0 ] && ! push_out=$(git push -u origin "$FEATURE_BRANCH" 2>&1); then
  echo "open-pr.sh: git push failed: $push_out" >&2
  _trace --level error PR "branch=$FEATURE_BRANCH success=false reason=push"
  exit 1
fi

# `gh pr view <branch>` also finds a merged or closed PR for the branch; only an open one is
# updated, anything else gets a new PR.
existing=$(gh pr view "$FEATURE_BRANCH" --json url,state,body,title,isDraft 2>/dev/null || true)
state=$(printf '%s' "$existing" | jq -r '.state // empty' 2>/dev/null || true)

if [ "$NO_PUSH" = 1 ] && [ "$state" != "OPEN" ]; then
  echo "PR: none"
  exit 0
fi

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
  title_args=()
  old_title=$(printf '%s' "$existing" | jq -r '.title // ""')
  if [ -n "$TITLE" ] && [ "$old_title" = "$FEATURE_SLUG" ]; then title_args=(--title "$TITLE"); fi
  # --no-push leaves the body alone: its block holds the closing lines and summary this run did not
  # rebuild. Only its draft marker is swapped for --draft-marker's, when the old body has a block.
  if [ "$NO_PUSH" = 0 ]; then
    gh pr edit "$FEATURE_BRANCH" --body-file "$TMP/body.md" "${title_args[@]+"${title_args[@]}"}" >/dev/null
  elif [ -n "$DRAFT_MARKER" ] && grep -qxF "$BEGIN_MARK" "$TMP/old.md"; then
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v marker="$DRAFT_MARKER" '
      $0 == begin { inblock = 1; done = 0 }
      inblock && $0 ~ /^<!-- crew-afk:draft .* -->$/ { if (!done) print marker; done = 1; next }
      inblock && $0 == end { if (!done) print marker; inblock = 0 }
      { print }
    ' "$TMP/old.md" > "$TMP/marked.md"
    cmp -s "$TMP/old.md" "$TMP/marked.md" || gh pr edit "$FEATURE_BRANCH" --body-file "$TMP/marked.md" >/dev/null
  fi
  url=$(printf '%s' "$existing" | jq -r '.url')
  is_draft=$(printf '%s' "$existing" | jq -r '.isDraft // false')
  if [ "$DRAFT" = 1 ] && [ "$is_draft" != "true" ]; then
    if out=$(gh pr ready --undo "$FEATURE_BRANCH" 2>&1); then is_draft=true; else state_failed="gh pr ready --undo failed: $out"; fi
  elif [ "$DRAFT" = 0 ] && [ "$is_draft" = "true" ]; then
    if out=$(gh pr ready "$FEATURE_BRANCH" 2>&1); then is_draft=false; else state_failed="gh pr ready failed: $out"; fi
  fi
else
  create() { gh pr create "$@" --head "$FEATURE_BRANCH" --title "${TITLE:-$FEATURE_SLUG}" --body-file "$TMP/block.md"; }
  is_draft=false
  if [ "$DRAFT" = 1 ]; then
    # A repo without draft PRs (a private repo on a free plan) refuses --draft: a ready PR, said
    # so, beats none; the crew-afk block's "Not green" note still says why.
    if out=$(create --draft 2>&1); then url=$(printf '%s\n' "$out" | tail -1); is_draft=true
    elif printf '%s' "$out" | grep -qi 'draft'; then state_failed="gh pr create --draft failed: $out"; url=$(create | tail -1)
    else echo "open-pr.sh: gh pr create failed: $out" >&2; exit 1
    fi
  else
    url=$(create | tail -1)
  fi
fi

_trace PR "branch=$FEATURE_BRANCH url=$url"
echo "PR: $url"
echo "PR-STATE: $([ "$is_draft" = true ] && echo draft || echo ready)"
[ -z "$state_failed" ] || echo "PR-STATE-FAILED: $(printf '%s' "$state_failed" | tr '\n' ' ')"
