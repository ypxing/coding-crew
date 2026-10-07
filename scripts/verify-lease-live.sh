#!/usr/bin/env bash
set -uo pipefail

# verify-lease-live.sh — maintainer-only: does the real `origin` accept the feature lease's
# refs? Runs lease.sh (create, CAS-reclaim, stale-CAS rejection, CAS-delete) against a throwaway
# slug and deletes it afterwards. It pushes to the remote, so it is opt-in:
#
#   CREW_LEASE_LIVE=1 scripts/verify-lease-live.sh [--remote-url <url>]
#
# With --remote-url the check runs in a scratch clone-less repo pointed at that URL (use a
# scratch repository); without it, the current repo's `origin` is used.
# Exit: 0 every step accepted · 1 a step failed (the namespace is rejected or unreachable) · 2 not opted in.

[ "${CREW_LEASE_LIVE:-}" = "1" ] || { echo "verify-lease-live: set CREW_LEASE_LIVE=1 to push a throwaway lease ref to origin" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEASE="$HERE/../skills/crew-afk/scripts/lease.sh"
[ -f "$LEASE" ] || LEASE="$HERE/../lease.sh"
URL=""
[ "${1:-}" = "--remote-url" ] && URL="${2:-}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if [ -n "$URL" ]; then
  git init -q "$TMP/r" && cd "$TMP/r" || exit 1
  git config user.email live@check; git config user.name live-check
  git commit -q --allow-empty -m live-check
  git remote add origin "$URL"
else
  cd "$(git rev-parse --show-toplevel)" || exit 1
fi
export MAIN_ROOT="$PWD"
SLUG="livecheck-$$-$(date +%s)"
NS="${CREW_LEASE_NAMESPACE:-refs/crew-lock}"
fail=0
step() { # step <name> <expected-exit> -- cmd…
  local name="$1" want="$2"; shift 3
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   $name"; else echo "FAIL $name (exit $rc, wanted $want): $out"; fail=1; fi
  LAST="$out"
}

step "create (annotated tag to $NS/$SLUG)" 0 -- bash "$LEASE" acquire --slug "$SLUG" --owner "run=live host=h pid=1 at=t"
if [ "$fail" -eq 0 ]; then
  first=$(sed -n 's/^SHA //p' <<<"$LAST")
  step "read back the owner" 0 -- bash "$LEASE" owner --slug "$SLUG"
  step "second create is rejected by the CAS" 3 -- bash "$LEASE" acquire --slug "$SLUG" --owner "run=live2 host=h pid=2 at=t"
  step "CAS-reclaim at the current sha" 0 -- bash "$LEASE" reclaim --slug "$SLUG" --expect "$first" --owner "run=live3 host=h pid=3 at=t"
  second=$(sed -n 's/^SHA //p' <<<"$LAST")
  step "CAS-reclaim at a stale sha is rejected" 3 -- bash "$LEASE" reclaim --slug "$SLUG" --expect "$first" --owner "run=live4 host=h pid=4 at=t"
  step "CAS-delete at a stale sha is rejected" 3 -- bash "$LEASE" release --slug "$SLUG" --expect "$first"
  step "CAS-delete at the current sha" 0 -- bash "$LEASE" release --slug "$SLUG" --expect "${second:-none}"
fi
step "lease is gone" 0 -- bash -c "[ \"\$(bash '$LEASE' owner --slug '$SLUG')\" = NONE ]"
# Whatever happened above, leave nothing behind.
git push -q origin ":$NS/$SLUG" >/dev/null 2>&1 || true

if [ "$fail" -eq 0 ]; then echo "PASS: origin accepts $NS/<slug> (create, CAS-reclaim, CAS-delete)"; exit 0; fi
echo "FAIL: origin rejected or mishandled $NS/<slug> — switch lease.sh/lease.mjs to a fallback namespace (see tracker/docs/github.md)"
exit 1
