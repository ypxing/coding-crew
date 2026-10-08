#!/usr/bin/env bash
set -uo pipefail

# issue-labels.sh — the one writer of crew-afk's status labels on a GitHub issue.
#
# Usage: issue-labels.sh claim|release|block <issue-number>
#        issue-labels.sh sweep <feature-slug>
#
# claim: a run is working this issue. Adds `in-progress` (created if the repo lacks it). Display
#   only — the feature lease, never this label, decides what is dispatched.
#   Prints `LABELLED: in-progress #<n>`.
# release: the run is done with the issue without closing it (partial, retained, capped, stalled).
#   Removes `in-progress`. Prints `RELEASED: in-progress #<n>`.
# block: crew-afk stopped on this issue and a human is needed. Adds the `blocked` label
#   (created if the repo lacks it) next to `ready-for-agent` and removes `in-progress`, in one
#   `gh issue edit`; selectDispatchable skips an issue carrying `blocked` until a human removes
#   it. Prints `LABELLED: blocked #<n>`.
# sweep: the new holder of the feature lease removes `in-progress` from every issue in the
#   feature's milestone — only a dead run can have left one. Prints `SWEPT: <count>`.
#
# Under `tracker: local` there is no label: prints nothing and exits 0.
# Exit 0 on success or when nothing applies; 1 when a gh call fails (caller warns, run goes on).

MAIN_ROOT="${MAIN_ROOT:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tracker-cli.sh
. "$SCRIPT_DIR/tracker-cli.sh"
resolve_tracker_cli "$MAIN_ROOT" || exit 1

CMD="${1:-}"
ARG="${2:-}"
USAGE="Usage: issue-labels.sh claim|release|block <issue-number> | sweep <feature-slug>"
case "$CMD" in
  claim|release|block)
    case "$ARG" in
      ''|*[!0-9]*) [ "$TRACKER_KIND" = "github" ] || exit 0
        echo "issue-labels.sh: expected a GitHub issue number, got: $ARG" >&2; exit 1 ;;
    esac ;;
  sweep)
    if [ -z "$ARG" ]; then echo "$USAGE" >&2; exit 1; fi ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac

[ "$TRACKER_KIND" = "github" ] || exit 0

# The label first, idempotently: --add-label and --remove-label fail on a label the repo lacks.
ensure_label() {
  local name="$1" description="$2" out
  if ! out="$(gh label create "$name" --force --description "$description" 2>&1)"; then
    echo "issue-labels.sh: gh label create $name failed: $out" >&2
    exit 1
  fi
}
ensure_blocked() { ensure_label blocked "crew-afk stopped on this issue; remove the label to put it back in the queue"; }
ensure_in_progress() { ensure_label in-progress "A crew-afk run is working this issue (display only)"; }

edit() {
  local out
  if ! out="$(gh issue edit "$1" "${@:2}" 2>&1)"; then
    echo "issue-labels.sh: gh issue edit failed for #$1: $out" >&2
    exit 1
  fi
}

case "$CMD" in
  claim)
    ensure_in_progress
    edit "$ARG" --add-label in-progress
    echo "LABELLED: in-progress #$ARG" ;;
  release)
    ensure_in_progress
    edit "$ARG" --remove-label in-progress
    echo "RELEASED: in-progress #$ARG" ;;
  block)
    ensure_blocked
    ensure_in_progress
    edit "$ARG" --add-label blocked --remove-label in-progress
    echo "LABELLED: blocked #$ARG" ;;
  sweep)
    if ! OUT="$(gh issue list --milestone "$ARG" --label in-progress --state all \
        --json number --jq '.[].number' 2>&1)"; then
      # A milestone not created yet has no issues, and so nothing to sweep.
      if printf '%s' "$OUT" | grep -qi milestone; then echo "SWEPT: 0"; exit 0; fi
      echo "issue-labels.sh: gh issue list failed: $OUT" >&2
      exit 1
    fi
    COUNT=0
    FAILED=0
    for N in $OUT; do
      if OUT2="$(gh issue edit "$N" --remove-label in-progress 2>&1)"; then
        COUNT=$((COUNT + 1))
      else
        echo "issue-labels.sh: gh issue edit failed for #$N: $OUT2" >&2
        FAILED=1
      fi
    done
    echo "SWEPT: $COUNT"
    [ "$FAILED" -eq 0 ] || exit 1 ;;
esac
