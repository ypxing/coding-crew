#!/usr/bin/env bash
set -uo pipefail

# issue-labels.sh — the one writer of crew-afk's status labels on a GitHub issue.
#
# Usage: issue-labels.sh block <issue-number>
#
# block: crew-afk stopped on this issue and a human is needed. Adds the `blocked` label
#   (created if the repo lacks it) next to `ready-for-agent`; selectDispatchable skips an issue
#   carrying it until the label is removed. Prints `LABELLED: blocked #<n>` on success.
#   Under `tracker: local` there is no label: prints nothing and exits 0.
#
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
NUMBER="${2:-}"
case "$CMD" in
  block) ;;
  *) echo "Usage: issue-labels.sh block <issue-number>" >&2; exit 1 ;;
esac
case "$NUMBER" in
  ''|*[!0-9]*) [ "$TRACKER_CONFIG_TRACKER" = "github" ] || exit 0
    echo "issue-labels.sh: expected a GitHub issue number, got: $NUMBER" >&2; exit 1 ;;
esac

[ "$TRACKER_CONFIG_TRACKER" = "github" ] || exit 0

REPO_ARGS=()
[ -n "$TRACKER_CONFIG_REPO" ] && REPO_ARGS=(--repo "$TRACKER_CONFIG_REPO")

# The label first, idempotently: --add-label fails on a label the repo lacks.
if ! OUT="$(gh label create blocked "${REPO_ARGS[@]}" --force \
    --description "crew-afk stopped on this issue; remove the label to put it back in the queue" 2>&1)"; then
  echo "issue-labels.sh: gh label create blocked failed: $OUT" >&2
  exit 1
fi
if ! OUT="$(gh issue edit "$NUMBER" "${REPO_ARGS[@]}" --add-label blocked 2>&1)"; then
  echo "issue-labels.sh: gh issue edit failed for #$NUMBER: $OUT" >&2
  exit 1
fi
echo "LABELLED: blocked #$NUMBER"
