#!/usr/bin/env bash
set -uo pipefail

# lease.sh — the feature lease: git ref refs/crew-lock/<slug> on origin, pointing at an
# annotated tag whose message names the owner (`run=… host=… pid=… at=…`).
#
# Usage:
#   lease.sh owner   --slug <f>                       print the holder, or NONE
#   lease.sh acquire --slug <f> --owner <msg>         create the ref; fails if it exists
#   lease.sh reclaim --slug <f> --expect <sha> --owner <msg>
#                                                     take over the lease at <sha>
#   lease.sh release --slug <f> --expect <sha>        delete the ref, only if still at <sha>
#
# Every write is a compare-and-swap: `git push --force-with-lease=<ref>:<expected-sha-or-empty>`.
# A plain push would silently overwrite an existing lease, since tag objects skip the
# fast-forward check.
#
# Output (stdout): owner → `NONE`, or `SHA <sha>` then `OWNER <message>`;
# acquire/reclaim → `SHA <sha>` of the lease just written.
# Exit: 0 done · 3 the compare-and-swap was rejected (someone else moved the ref) · 1 error.
# Runs in $MAIN_ROOT (default: the git toplevel).

CMD="${1:-}"; [ $# -gt 0 ] && shift
SLUG=""; OWNER=""; EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    *) echo "lease.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$SLUG" ] || { echo "lease.sh: --slug is required" >&2; exit 1; }
MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$MAIN_ROOT" || exit 1
REF="refs/crew-lock/$SLUG"

# Exact ref only: ls-remote also prints the peeled `<ref>^{}` line for an annotated tag.
remote_sha() {
  local out
  out=$(git ls-remote origin "$REF" 2>&1) || { echo "lease.sh: git ls-remote origin failed: $out" >&2; return 1; }
  printf '%s\n' "$out" | awk -v ref="$REF" '$2 == ref { print $1; exit }'
}

# push <local-src-or-empty> <expected-sha-or-empty>
cas_push() {
  local out
  if out=$(git push --force-with-lease="$REF:$2" origin "$1:$REF" 2>&1); then return 0; fi
  if printf '%s' "$out" | grep -Eqi 'stale info|rejected|already exists|failed to delete'; then return 3; fi
  echo "lease.sh: git push failed: $out" >&2
  return 1
}

make_tag() {
  local target
  target=$(git rev-parse HEAD 2>/dev/null) || { echo "lease.sh: no commit to tag" >&2; return 1; }
  printf 'object %s\ntype commit\ntag crew-lock\ntagger crew-afk <crew-afk@localhost> %s +0000\n\n%s\n' \
    "$target" "$(date +%s)" "$OWNER" | git mktag
}

write_lease() {
  [ -n "$OWNER" ] || { echo "lease.sh: --owner is required" >&2; exit 1; }
  local sha rc
  sha=$(make_tag) || exit 1
  cas_push "$sha" "$1"; rc=$?
  [ $rc -eq 0 ] && echo "SHA $sha"
  exit $rc
}

case "$CMD" in
  owner)
    sha=$(remote_sha) || exit 1
    if [ -z "$sha" ]; then echo NONE; exit 0; fi
    # A local scratch copy of the ref, only to read the tag message.
    git fetch -q --no-tags origin "+$REF:refs/crew-lock-read/$SLUG" 2>/dev/null || { echo "lease.sh: cannot fetch $REF" >&2; exit 1; }
    msg=$(git cat-file tag "refs/crew-lock-read/$SLUG" 2>/dev/null | sed '1,/^$/d' | head -n 1)
    git update-ref -d "refs/crew-lock-read/$SLUG" 2>/dev/null
    echo "SHA $sha"
    echo "OWNER $msg"
    ;;
  acquire) write_lease "" ;;
  reclaim)
    [ -n "$EXPECT" ] || { echo "lease.sh: --expect is required" >&2; exit 1; }
    write_lease "$EXPECT" ;;
  release)
    [ -n "$EXPECT" ] || { echo "lease.sh: --expect is required" >&2; exit 1; }
    cas_push "" "$EXPECT"; exit $? ;;
  *) echo "usage: lease.sh owner|acquire|reclaim|release --slug <f> [--expect <sha>] [--owner <msg>]" >&2; exit 1 ;;
esac
