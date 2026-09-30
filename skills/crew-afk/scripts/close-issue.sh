#!/usr/bin/env bash
set -euo pipefail

# close-issue.sh — mechanical issue close: rewrite Status line and move file
#
# Usage: close-issue.sh <issue-file-path>                 # tracker: local
#        close-issue.sh <issue-number> <branch>            # tracker: github — the
#        branch is required so receipts.sh can check the ac receipt without a file
#        path to derive a feature/slug from (see receipts.sh's own comment on this).
#
# What it does:
#   1. Validates the issue file exists.
#   2. Requires an acceptance-criteria receipt for *this issue's own slug*
#      (see receipts.sh). Without it the issue is not closed. This is what stops
#      an issue being closed off a sibling issue's verified branch — observed in
#      a real sprint, where one dispatch produced two "merged" issues.
#   3. Rewrites the `Status:` line to `Status: done` and ticks every remaining
#      `- [ ]` under `## Acceptance criteria` / `## Cross-cutting Requirements`.
#   4. Moves the file from .../issues/open/ to .../issues/done/.
#
# Why the check-off lives here
#   It used to be the worker's job (solve-issue step 7), which made it
#   self-attestation: mark-issue-done.sh refuses to close while a `- [ ]` remains
#   (exit 4), a gate any worker defeats by ticking its own boxes — the exact thing
#   the reviewer-owned acceptance-criteria gate exists to prevent. The tick is
#   bookkeeping *about* a close, so it belongs to whatever performs the close, and
#   it happens only after the receipt gate below has passed.
#
# What it does NOT do:
#   - Verify acceptance criteria (that is a separate agent step, run pre-merge, before this).
#     This only demands the receipt that step leaves behind.
#   - Any judgment or content analysis.

ISSUE_PATH="${1:-}"

if [ -z "$ISSUE_PATH" ]; then
  echo "Usage: $0 <issue-file-path>" >&2
  exit 1
fi

# ─── tracker backend: local (file path) or github (issue number) ────────────
#
# tracker-config.sh (issue 01) is not a sibling of this script either in the
# source tree (skills/crew-afk/scripts/) or once installed (.coding-crew/scripts/,
# alongside mark-issue-done.sh) — it lives under the main checkout's root, so it
# is looked up relative to MAIN_ROOT instead. Finding none of the candidates is
# not an error: it means `tracker: local`, tracker-config.sh's own zero-config
# default, so an in-between install state can never break the local path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_ROOT="${MAIN_ROOT:-.}"
# BEGIN tracker-lookup — identical in every caller; tests/tracker-lookup.bats fails if one drifts.
# Where tracker-config.sh (and mark-issue-done.sh beside it) are looked for, first hit wins.
# It cannot live in tracker-config.sh itself: that is the file being looked for.
tracker_config_candidates() {
  local main_root="$1" c
  for c in "${CREW_TRACKER_CONFIG:-}" \
    "${CREW_INSTALL_DIR:+$CREW_INSTALL_DIR/scripts/tracker-config.sh}" \
    "$main_root/.coding-crew/scripts/tracker-config.sh" \
    "$main_root/scripts/tracker/tracker-config.sh" \
    "${HOME:+$HOME/.coding-crew/scripts/tracker-config.sh}"; do
    if [ -n "$c" ]; then printf '%s\n' "$c"; fi
  done
  return 0
}
# END tracker-lookup
TRACKER_CONFIG_TRACKER="local"
TRACKER_CONFIG_REPO=""
TRACKER_CONFIG_FOUND=""
while IFS= read -r _tc; do
  if [ -f "$_tc" ]; then TRACKER_CONFIG_FOUND="$_tc"; break; fi
done < <(tracker_config_candidates "$MAIN_ROOT")
if [ -n "$TRACKER_CONFIG_FOUND" ]; then
  # shellcheck source=/dev/null
  . "$TRACKER_CONFIG_FOUND"
  read_tracker_config "$MAIN_ROOT"
fi

if [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
  # ─────────────────────────── github backend ────────────────────────────
  #
  # The argument is a GitHub issue number here, not a file path. Who is allowed
  # to trigger this close is unchanged — the same ac-receipt gate as local, keyed
  # on the same argument — only how the close itself happens differs.
  ISSUE_NUMBER="$ISSUE_PATH"
  case "$ISSUE_NUMBER" in
    ''|*[!0-9]*)
      echo "ERROR: expected a GitHub issue number under tracker: github, got: $ISSUE_NUMBER" >&2
      exit 1 ;;
  esac

  RECEIPTS_SCRIPT="$SCRIPT_DIR/receipts.sh"
  _trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }
  # CREW_RECEIPTS=off is the same escape hatch receipts.sh's own receipts_enabled() grants
  # (see its header comment) — mirrored here, not just left to receipts.sh, because a
  # missing branch arg must not become a hard error when no check is going to run at all.
  if [ -f "$RECEIPTS_SCRIPT" ] && [ "${CREW_RECEIPTS:-on}" != "off" ]; then
    # No issue file path to derive a feature/slug from (see receipts.sh's own comment on
    # this) — the branch is the one thing both the write (runHousekeeping, pre-merge) and
    # this check agree on, so receipts.sh splits it the same way for both.
    BRANCH_ARG="${2:-}"
    if [ -z "$BRANCH_ARG" ]; then
      echo "ERROR: tracker: github requires the branch as a second argument: $0 <issue-number> <branch>" >&2
      exit 1
    fi
    bash "$RECEIPTS_SCRIPT" check ac --branch "$BRANCH_ARG"
  fi

  # "Done" here is merged into the feature branch, not shipped, so the issue stays open,
  # labelled awaiting-merge: the feature PR's `Closes #n` closes it on merge. That label
  # swap is mark-issue-done.sh's, installed beside tracker-config.sh; --force because
  # criteria were already re-verified pre-merge (the receipt above is that fact) and this
  # sprint's own .orchestrated marker would otherwise refuse it.
  bash "$(dirname "$TRACKER_CONFIG_FOUND")/mark-issue-done.sh" "$ISSUE_NUMBER" --force >/dev/null

  _trace CLOSE "issue=$ISSUE_NUMBER"

  echo "Closed: issue #$ISSUE_NUMBER (github: awaiting-merge — the feature PR's Closes #$ISSUE_NUMBER closes it)"
  exit 0
fi

# ─────────────────────────── local backend (byte-identical to today) ────────

# finalize_issue — mark an issue file closed: Status: done, plus every criterion ticked.
#
# One awk pass, written to a temp file and moved into place. `sed -i` is not portable
# (GNU takes a bare -i, BSD/macOS reads the next argument as a backup suffix, and
# `-i''` does not help — the shell strips the empty quotes), and one pass means the
# file is never observable half-rewritten.
#
# Section scoping matches mark-issue-done.sh's guard exactly, so the two agree on
# which boxes are criteria: only those under an acceptance-criteria or
# cross-cutting-requirements heading. A `- [ ]` in `## What to build` or `## Notes`
# is somebody's note, not a criterion, and is left alone.
finalize_issue() {
  local file="$1"
  local tmp="${file}.tmp.$$"

  awk '
    /^Status:[ 	]*/ { print "Status: done"; next }
    /^##+[ 	]*[Aa]cceptance [Cc]riteria/       { inside = 1; print; next }
    /^##+[ 	]*[Cc]ross-cutting [Rr]equirements/ { inside = 1; print; next }
    /^##/                                       { inside = 0; print; next }
    inside && /^[ 	]*[-*][ 	]+\[[ ]\]/ { sub(/\[[ ]\]/, "[x]"); print; next }
    { print }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"; echo "ERROR: could not rewrite $file" >&2; return 1; }

  mv "$tmp" "$file"
}

if [ ! -f "$ISSUE_PATH" ]; then
  # A worker that closed the issue itself, or a re-run of this step, leaves the file
  # in the sibling done/ directory. That is the desired end state, so report it and
  # succeed rather than aborting the orchestrator mid-pipeline. No receipt is
  # demanded here: there is no state left to change, so refusing would only make
  # re-runs fail.
  _open_dir=$(dirname "$ISSUE_PATH")
  _already="$(dirname "$_open_dir")/done/$(basename "$ISSUE_PATH")"
  if [ -f "$_already" ]; then
    finalize_issue "$_already"
    echo "Closed: $(basename "$ISSUE_PATH") → $_already (already closed)"
    exit 0
  fi
  echo "ERROR: issue file not found: $ISSUE_PATH" >&2
  exit 1
fi

# Require this issue's own acceptance-criteria receipt before changing anything.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPTS_SCRIPT="$SCRIPT_DIR/receipts.sh"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }
if [ -f "$RECEIPTS_SCRIPT" ]; then
  bash "$RECEIPTS_SCRIPT" check ac --issue "$ISSUE_PATH"
fi

# Status: done, and every criterion ticked. Only reached once the receipt gate above
# has passed — a refused close leaves the file exactly as the worker left it.
finalize_issue "$ISSUE_PATH"

# Move to sibling done/ directory
OPEN_DIR=$(dirname "$ISSUE_PATH")
DONE_DIR=$(dirname "$OPEN_DIR")/done
mkdir -p "$DONE_DIR"

FILENAME=$(basename "$ISSUE_PATH")
mv "$ISSUE_PATH" "$DONE_DIR/$FILENAME"

_trace CLOSE "issue=$FILENAME"

echo "Closed: $FILENAME → $DONE_DIR/$FILENAME"
