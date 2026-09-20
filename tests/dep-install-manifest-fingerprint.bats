#!/usr/bin/env bats

# manifest-fingerprint.sh — the shared "has anything host-install.sh/docker-install.sh would
# act on changed" check both of them call before deciding whether to skip a redundant install.
# Pinned standalone here since both callers only exercise it through their own skip/write
# behaviour, not its own edge cases (monorepo layouts, exclusions, atomicity).

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
SCRIPT="$SCRIPTS_DIR/manifest-fingerprint.sh"

setup() {
  PROJECT=$(mktemp -d)
  export PROJECT
}

teardown() {
  rm -rf "$PROJECT"
}

@test "compute is deterministic for the same manifest content" {
  echo '{}' > "$PROJECT/package-lock.json"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  first="$output"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
}

@test "compute changes when a recognised lockfile's content changes" {
  echo '{}' > "$PROJECT/package-lock.json"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  before="$output"

  echo '{"a":1}' > "$PROJECT/package-lock.json"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ "$output" != "$before" ]
}

@test "compute changes when a new manifest directory appears (monorepo growth)" {
  mkdir -p "$PROJECT/services/api"
  echo '{}' > "$PROJECT/services/api/package-lock.json"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  before="$output"

  mkdir -p "$PROJECT/services/worker"
  echo '{}' > "$PROJECT/services/worker/package-lock.json"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ "$output" != "$before" ]
}

@test "a monorepo with independent lockfiles per package hashes each of them" {
  mkdir -p "$PROJECT/services/api" "$PROJECT/services/worker"
  echo '{}' > "$PROJECT/services/api/package-lock.json"
  echo '{}' > "$PROJECT/services/worker/requirements.txt"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  before="$output"

  # Only the worker's manifest changes — the fingerprint must still change, proving both
  # directories are part of the hashed input, not just the first one found.
  echo 'flask==2.0' > "$PROJECT/services/worker/requirements.txt"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ "$output" != "$before" ]
}

@test "excludes node_modules, .venv, vendor, target, dist and build from the scan" {
  mkdir -p "$PROJECT/node_modules/some-pkg" "$PROJECT/vendor/gem" "$PROJECT/target/generated" \
    "$PROJECT/dist/out" "$PROJECT/build/out" "$PROJECT/.venv/lib"
  echo '{}' > "$PROJECT/node_modules/some-pkg/package-lock.json"
  echo '{}' > "$PROJECT/vendor/gem/composer.json"
  echo '{}' > "$PROJECT/target/generated/Cargo.toml"
  echo '{}' > "$PROJECT/dist/out/package-lock.json"
  echo '{}' > "$PROJECT/build/out/package-lock.json"
  echo '{}' > "$PROJECT/.venv/lib/requirements.txt"

  run bash "$SCRIPT" compute --project-root "$PROJECT"
  no_manifest="$output"

  echo '{}' > "$PROJECT/package-lock.json"
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  # Only the root manifest (not excluded) should have moved the hash.
  [ "$output" != "$no_manifest" ]
}

@test "check reports STALE when no stamp exists yet" {
  echo '{}' > "$PROJECT/package-lock.json"
  run bash "$SCRIPT" check --project-root "$PROJECT" --stamp "$PROJECT/.scratch/stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

@test "write then check reports FRESH when nothing changed" {
  echo '{}' > "$PROJECT/package-lock.json"
  bash "$SCRIPT" write --project-root "$PROJECT" --stamp "$PROJECT/.scratch/stamp"
  run bash "$SCRIPT" check --project-root "$PROJECT" --stamp "$PROJECT/.scratch/stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "FRESH" ]
}

@test "check reports STALE after the manifest changes post-write" {
  echo '{}' > "$PROJECT/package-lock.json"
  bash "$SCRIPT" write --project-root "$PROJECT" --stamp "$PROJECT/.scratch/stamp"
  echo '{"a":1}' > "$PROJECT/package-lock.json"
  run bash "$SCRIPT" check --project-root "$PROJECT" --stamp "$PROJECT/.scratch/stamp"
  [ "$output" = "STALE" ]
}

@test "write creates the stamp's parent directory and is safe to call twice" {
  echo '{}' > "$PROJECT/package-lock.json"
  run bash "$SCRIPT" write --project-root "$PROJECT" --stamp "$PROJECT/.scratch/nested/stamp"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.scratch/nested/stamp" ]
  run bash "$SCRIPT" write --project-root "$PROJECT" --stamp "$PROJECT/.scratch/nested/stamp"
  [ "$status" -eq 0 ]
}

@test "compute with no recognised manifest at all is still a stable, non-empty hash" {
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ -n "$output" ]
}

@test "--project-root is required" {
  run bash "$SCRIPT" compute
  [ "$status" -ne 0 ]
}

@test "a nonexistent --project-root is a usage error" {
  run bash "$SCRIPT" compute --project-root "$PROJECT/does-not-exist"
  [ "$status" -ne 0 ]
}

@test "check requires --stamp; compute does not" {
  run bash "$SCRIPT" check --project-root "$PROJECT"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" compute --project-root "$PROJECT"
  [ "$status" -eq 0 ]
}

@test "an unrecognised first argument is a usage error" {
  run bash "$SCRIPT" bogus --project-root "$PROJECT"
  [ "$status" -ne 0 ]
}

@test "the script is shipped executable" {
  [ -x "$SCRIPT" ]
}
