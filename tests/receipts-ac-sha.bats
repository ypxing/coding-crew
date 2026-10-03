#!/usr/bin/env bats
# `receipts.sh write ac --sha`: the receipt names the reviewed commit, so a moved tip is stale.

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO" && cd "$REPO"
  git init -q -b main . && git config user.email t@t && git config user.name t
  git commit -q --allow-empty -m base
  git checkout -q -b crew/demo/alpha
  git commit -q --allow-empty -m one
  REVIEWED=$(git rev-parse HEAD)
  git checkout -q main
  R="$BATS_TEST_DIRNAME/../skills/crew-afk/scripts/receipts.sh"
}

@test "ac receipt with --sha records that commit; check --at-tip refuses once the branch moved" {
  run bash "$R" write ac --branch crew/demo/alpha --sha "$REVIEWED"
  [ "$status" -eq 0 ]
  git checkout -q crew/demo/alpha && git commit -q --allow-empty -m two && git checkout -q main
  run bash "$R" check ac --branch crew/demo/alpha --at-tip
  [ "$status" -eq 1 ]
  [[ "$output" == *"not at its tip"* ]]
}

@test "ac receipt without --sha still names the tip and passes --at-tip" {
  run bash "$R" write ac --branch crew/demo/alpha
  [ "$status" -eq 0 ]
  run bash "$R" check ac --branch crew/demo/alpha --at-tip
  [ "$status" -eq 0 ]
}

@test "an unknown --sha fails the write" {
  run bash "$R" write ac --branch crew/demo/alpha --sha deadbeefdeadbeef
  [ "$status" -eq 1 ]
}
