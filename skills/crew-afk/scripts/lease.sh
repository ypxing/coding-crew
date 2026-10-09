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
# Exit: 0 done · 3 the compare-and-swap was rejected (someone else moved the ref) ·
# 4 the host itself refuses the ref namespace (the message names the fallback) · 1 error.
#
# Namespace: refs/crew-lock/<slug> by default — verified against github.com (create, CAS-reclaim,
# CAS-delete; see tracker/docs/github.md). A host that refuses it can be pointed at the
# fallback with CREW_LEASE_NAMESPACE=refs/tags/crew-lock, which every host accepts. Set it for
# lease.sh and the orchestrator alike (lease.mjs reads the same variable).
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
NS="${CREW_LEASE_NAMESPACE:-refs/crew-lock}"
NS="${NS%/}"
REF="$NS/$SLUG"

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
  # A host refusing the namespace outright is not a lost race: it never goes away on retry.
  if printf '%s' "$out" | grep -Eqi 'remote rejected.*(hook declined|deny|denied|not allowed|refusing|protected|forbidden|invalid|restricted)|deny updating|hidden ref'; then
    echo "lease.sh: origin rejected the lease ref $REF (the host refuses this ref namespace): $out" >&2
    echo "lease.sh: use the fallback namespace: export CREW_LEASE_NAMESPACE=refs/tags/crew-lock" >&2
    return 4
  fi
  if printf '%s' "$out" | grep -Eqi 'stale info|rejected|already exists|failed to delete'; then return 3; fi
  echo "lease.sh: git push failed: $out" >&2
  return 1
}

# The tag points at a commit origin already has, so pushing the lease uploads nothing else: never
# HEAD, which is the user's own branch in the main checkout and may hold commits they have not
# pushed. origin's default branch, else any branch of origin's; HEAD only when origin has none yet.
lease_target() {
  local target
  target=$(git rev-parse -q --verify "refs/remotes/origin/HEAD^{commit}" 2>/dev/null) && { echo "$target"; return 0; }
  target=$(git for-each-ref --count=1 --format='%(objectname)' refs/remotes/origin/ 2>/dev/null)
  [ -n "$target" ] && { echo "$target"; return 0; }
  git rev-parse -q --verify "HEAD^{commit}" 2>/dev/null
}

make_tag() {
  local target
  target=$(lease_target) || { echo "lease.sh: no commit to tag" >&2; return 1; }
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
