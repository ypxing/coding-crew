#!/usr/bin/env bats

# lease.sh — the feature lease, against a real bare repo as origin.

LEASE="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/lease.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  git init -q --bare "$TEMP_DIR/remote.git"
  # No detached auto-gc/maintenance: one still writing objects/pack after a fetch or push races teardown's rm -rf
  git -C "$TEMP_DIR/remote.git" config receive.autogc false
  export MAIN_ROOT="$TEMP_DIR/repo"
  git init -q -b main "$MAIN_ROOT"
  cd "$MAIN_ROOT"
  git config gc.auto 0
  git config maintenance.auto false
  git config user.email t@test
  git config user.name T
  git commit -q --allow-empty -m init
  git remote add origin "$TEMP_DIR/remote.git"
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "owner: NONE when no lease" {
  run bash "$LEASE" owner --slug f
  [ "$status" -eq 0 ]
  [ "$output" = "NONE" ]
}

@test "acquire then owner reads the message, ignoring the peeled line" {
  run bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=2026-01-01T00:00:00Z"
  [ "$status" -eq 0 ]
  # ls-remote prints the peeled line too for an annotated tag
  [ "$(git ls-remote origin 'refs/crew-lock/f*' | wc -l)" -eq 2 ]
  run bash "$LEASE" owner --slug f
  [ "$status" -eq 0 ]
  [[ "$output" == *"OWNER run=r1 host=h pid=1 at=2026-01-01T00:00:00Z"* ]]
  [ "$(git ls-remote origin refs/crew-lock/f | cut -f1)" = "$(echo "$output" | awk '/^SHA/{print $2}')" ]
}

@test "a competing create is rejected by the CAS" {
  bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=t"
  sha=$(git ls-remote origin refs/crew-lock/f | cut -f1)
  run bash "$LEASE" acquire --slug f --owner "run=r2 host=h pid=2 at=t"
  [ "$status" -eq 3 ]
  [ "$(git ls-remote origin refs/crew-lock/f | cut -f1)" = "$sha" ]
}

@test "two reclaimers on the same stale sha: exactly one wins" {
  bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=t"
  stale=$(git ls-remote origin refs/crew-lock/f | cut -f1)
  run bash "$LEASE" reclaim --slug f --expect "$stale" --owner "run=r2 host=h pid=2 at=t"
  [ "$status" -eq 0 ]
  run bash "$LEASE" reclaim --slug f --expect "$stale" --owner "run=r3 host=h pid=3 at=t"
  [ "$status" -eq 3 ]
  run bash "$LEASE" owner --slug f
  [[ "$output" == *"run=r2"* ]]
}

@test "release deletes only when still at the expected sha" {
  bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=t"
  mine=$(git ls-remote origin refs/crew-lock/f | cut -f1)
  run bash "$LEASE" reclaim --slug f --expect "$mine" --owner "run=r2 host=h pid=2 at=t"
  [ "$status" -eq 0 ]
  run bash "$LEASE" release --slug f --expect "$mine"
  [ "$status" -eq 3 ]
  [ -n "$(git ls-remote origin refs/crew-lock/f)" ]
  now=$(git ls-remote origin refs/crew-lock/f | cut -f1)
  run bash "$LEASE" release --slug f --expect "$now"
  [ "$status" -eq 0 ]
  [ -z "$(git ls-remote origin refs/crew-lock/f)" ]
}

@test "the lease points at a commit origin already has: the main checkout's unpushed commits stay local" {
  git push -q origin main
  git fetch -q origin
  git checkout -q -b wip
  git commit -q --allow-empty -m "private wip"
  wip=$(git rev-parse HEAD)
  run bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=t"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TEMP_DIR/remote.git" rev-parse 'refs/crew-lock/f^{commit}')" = "$(git rev-parse origin/main)" ]
  run git -C "$TEMP_DIR/remote.git" cat-file -e "$wip"
  [ "$status" -ne 0 ]
}

@test "no origin is an error, not a rejection" {
  git remote remove origin
  run bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=t"
  [ "$status" -eq 1 ]
}

@test "a host that refuses the namespace: exit 4 naming the fallback, not a lost race" {
  printf '#!/bin/sh\nwhile read old new ref; do case "$ref" in refs/crew-lock/*) echo "namespace not allowed" >&2; exit 1;; esac; done\n' \
    > "$TEMP_DIR/remote.git/hooks/pre-receive"
  chmod +x "$TEMP_DIR/remote.git/hooks/pre-receive"
  run bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=t"
  [ "$status" -eq 4 ]
  [[ "$output" == *"rejected the lease ref refs/crew-lock/f"* ]]
  [[ "$output" == *"CREW_LEASE_NAMESPACE=refs/tags/crew-lock"* ]]
}

@test "CREW_LEASE_NAMESPACE moves the whole lease to the fallback namespace" {
  export CREW_LEASE_NAMESPACE=refs/tags/crew-lock
  run bash "$LEASE" acquire --slug f --owner "run=r1 host=h pid=1 at=t"
  [ "$status" -eq 0 ]
  [ -n "$(git ls-remote origin refs/tags/crew-lock/f)" ]
  [ -z "$(git ls-remote origin refs/crew-lock/f)" ]
  run bash "$LEASE" owner --slug f
  [[ "$output" == *"OWNER run=r1"* ]]
  sha=$(git ls-remote origin refs/tags/crew-lock/f | cut -f1 | head -1)
  run bash "$LEASE" release --slug f --expect "$sha"
  [ "$status" -eq 0 ]
  [ -z "$(git ls-remote origin refs/tags/crew-lock/f)" ]
}

# Opt-in: pushes a throwaway lease ref to the real origin (see scripts/verify-lease-live.sh).
@test "live: origin accepts create, CAS-reclaim and CAS-delete of refs/crew-lock/<slug>" {
  [ "${CREW_LEASE_LIVE:-}" = "1" ] || skip "set CREW_LEASE_LIVE=1 to push to the real origin"
  cd "$(dirname "$LEASE")/../../.."
  run env CREW_LEASE_LIVE=1 bash scripts/verify-lease-live.sh
  echo "$output"
  [ "$status" -eq 0 ]
}
