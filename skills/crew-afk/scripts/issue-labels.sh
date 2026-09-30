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
# BEGIN tracker-lookup — identical in every caller; tests/tracker-lookup.bats fails if one drifts.
# Where tracker-config.sh (and mark-issue-done.sh beside it) are looked for, first hit wins.
# It cannot live in tracker-config.sh itself: that is the file being looked for.
# Callers break on the first hit, closing the pipe while this may still be writing; where
# SIGPIPE is ignored that write fails with "Broken pipe", so it stops quietly instead.
tracker_config_candidates() {
  local main_root="$1" c
  for c in "${CREW_TRACKER_CONFIG:-}" \
    "${CREW_INSTALL_DIR:+$CREW_INSTALL_DIR/scripts/tracker-config.sh}" \
    "$main_root/.coding-crew/scripts/tracker-config.sh" \
    "$main_root/scripts/tracker/tracker-config.sh" \
    "${HOME:+$HOME/.coding-crew/scripts/tracker-config.sh}"; do
    if [ -n "$c" ]; then printf '%s\n' "$c" 2>/dev/null || return 0; fi
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

CMD="${1:-}"
ARG="${2:-}"
USAGE="Usage: issue-labels.sh claim|release|block <issue-number> | sweep <feature-slug>"
case "$CMD" in
  claim|release|block)
    case "$ARG" in
      ''|*[!0-9]*) [ "$TRACKER_CONFIG_TRACKER" = "github" ] || exit 0
        echo "issue-labels.sh: expected a GitHub issue number, got: $ARG" >&2; exit 1 ;;
    esac ;;
  sweep)
    if [ -z "$ARG" ]; then echo "$USAGE" >&2; exit 1; fi ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac

[ "$TRACKER_CONFIG_TRACKER" = "github" ] || exit 0

REPO_ARGS=()
[ -n "$TRACKER_CONFIG_REPO" ] && REPO_ARGS=(--repo "$TRACKER_CONFIG_REPO")

# The label first, idempotently: --add-label and --remove-label fail on a label the repo lacks.
ensure_label() {
  local name="$1" description="$2" out
  if ! out="$(gh label create "$name" "${REPO_ARGS[@]}" --force --description "$description" 2>&1)"; then
    echo "issue-labels.sh: gh label create $name failed: $out" >&2
    exit 1
  fi
}
ensure_blocked() { ensure_label blocked "crew-afk stopped on this issue; remove the label to put it back in the queue"; }
ensure_in_progress() { ensure_label in-progress "A crew-afk run is working this issue (display only)"; }

edit() {
  local out
  if ! out="$(gh issue edit "$1" "${REPO_ARGS[@]}" "${@:2}" 2>&1)"; then
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
    if ! OUT="$(gh issue list "${REPO_ARGS[@]}" --milestone "$ARG" --label in-progress --state all \
        --json number --jq '.[].number' 2>&1)"; then
      # A milestone not created yet has no issues, and so nothing to sweep.
      if printf '%s' "$OUT" | grep -qi milestone; then echo "SWEPT: 0"; exit 0; fi
      echo "issue-labels.sh: gh issue list failed: $OUT" >&2
      exit 1
    fi
    COUNT=0
    FAILED=0
    for N in $OUT; do
      if OUT2="$(gh issue edit "$N" "${REPO_ARGS[@]}" --remove-label in-progress 2>&1)"; then
        COUNT=$((COUNT + 1))
      else
        echo "issue-labels.sh: gh issue edit failed for #$N: $OUT2" >&2
        FAILED=1
      fi
    done
    echo "SWEPT: $COUNT"
    [ "$FAILED" -eq 0 ] || exit 1 ;;
esac
