#!/usr/bin/env bats

# Tests for CHANGELOG.md [1.5.0] entry

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export CHANGELOG="$SCRIPT_DIR/CHANGELOG.md"
}

@test "CHANGELOG.md has a [1.5.0] entry" {
  grep -q '^\#\# \[1\.5\.0\]' "$CHANGELOG"
}

@test "CHANGELOG.md [1.5.0] entry has the correct date 2026-06-20" {
  grep -q '^\#\# \[1\.5\.0\] - 2026-06-20' "$CHANGELOG"
}

@test "CHANGELOG.md [1.5.0] entry appears before [1.4.0]" {
  line_150=$(grep -n '^\#\# \[1\.5\.0\]' "$CHANGELOG" | head -1 | cut -d: -f1)
  line_140=$(grep -n '^\#\# \[1\.4\.0\]' "$CHANGELOG" | head -1 | cut -d: -f1)
  [ -n "$line_150" ]
  [ -n "$line_140" ]
  [ "$line_150" -lt "$line_140" ]
}

@test "CHANGELOG.md [1.5.0] breaking change documents crew-plan renamed to crew-grill" {
  # Extract the 1.5.0 section (between ## [1.5.0] and ## [1.4.0])
  awk '/^## \[1\.5\.0\]/{found=1} /^## \[1\.4\.0\]/{found=0} found{print}' "$CHANGELOG" | \
    grep -q 'crew-plan'
  awk '/^## \[1\.5\.0\]/{found=1} /^## \[1\.4\.0\]/{found=0} found{print}' "$CHANGELOG" | \
    grep -q 'crew-grill'
}

@test "CHANGELOG.md [1.5.0] breaking change section has migration table" {
  section=$(awk '/^## \[1\.5\.0\]/{found=1} /^## \[1\.4\.0\]/{found=0} found{print}' "$CHANGELOG")
  echo "$section" | grep -q '| *`crew-plan`'
  echo "$section" | grep -q '| *`crew-grill`'
}

@test "CHANGELOG.md [1.5.0] breaking change section has reinstall instructions" {
  section=$(awk '/^## \[1\.5\.0\]/{found=1} /^## \[1\.4\.0\]/{found=0} found{print}' "$CHANGELOG")
  echo "$section" | grep -q 'unbootstrap.sh'
  echo "$section" | grep -q 'bootstrap.sh'
}

@test "CHANGELOG.md [1.5.0] added section documents crew-brainstorm" {
  section=$(awk '/^## \[1\.5\.0\]/{found=1} /^## \[1\.4\.0\]/{found=0} found{print}' "$CHANGELOG")
  echo "$section" | grep -q 'crew-brainstorm'
}

@test "CHANGELOG.md [1.5.0] changed section documents to-issues enhancements" {
  section=$(awk '/^## \[1\.5\.0\]/{found=1} /^## \[1\.4\.0\]/{found=0} found{print}' "$CHANGELOG")
  echo "$section" | grep -q 'to-issues'
}
