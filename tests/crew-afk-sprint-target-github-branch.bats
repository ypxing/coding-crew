#!/usr/bin/env bats

# Tests for crew-afk's "Resolving the sprint target" step in each platform's launcher body:
# it lists features with the tracker CLI's `features` op (#371), which answers for a github
# milestone as well as a local `.scratch/<slug>/`, and runs no `ls`/`grep` over `.scratch/`
# nor any direct gh call (#331: skills reach the tracker only through the tracker CLI).
#
# This is prompt text, not runtime code, so the "unit test" here is a content check,
# consistent across all platforms.

load helpers/render

FEATURES_LINE='node "$TRACKER" features'

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

# sprint_target_fence <platform> — prints the content of the first ```bash ... ``` code
# fence inside the "## Resolving the sprint target" section (the fence the local ls/grep
# lines live in, and where a github-equivalent line must sit alongside them) of the
# rendered launcher for that platform.
sprint_target_fence() {
  local body
  body="$(afk_variant "$1")"
  awk '
    /^## Resolving the sprint target/ { insection=1; next }
    insection && /^```bash/ { infence=1; next }
    infence && /^```/ { exit }
    infence { print }
  ' "$body"
}

@test "sprint target: the fence lists features through the tracker CLI, in every platform variant" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    [[ "$fence" == *"$FEATURES_LINE"* ]] || {
      echo "$p: the fence does not run features" >&2; return 1; }
  done
}

@test "sprint target: the fence runs no ls or grep over .scratch" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    [[ "$fence" != *".scratch"* ]] || {
      echo "$p: the fence still scans .scratch" >&2; return 1; }
  done
}

@test "sprint target: the fence carries no direct gh call — skills reach the tracker only through the tracker CLI (#331)" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    [[ "$fence" != *"gh issue"* ]] || {
      echo "$p: sprint-target fence still calls gh directly" >&2; return 1; }
  done
}

@test "sprint target: all four platform variants add the exact same github branch (consistent, not drifted)" {
  local first="" first_p="" fence
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    if [ -z "$first_p" ]; then
      first="$fence"
      first_p="$p"
    else
      [ "$fence" = "$first" ] || {
        echo "$p's sprint-target code fence differs from $first_p's" >&2
        diff <(printf '%s' "$first") <(printf '%s' "$fence") >&2
        return 1
      }
    fi
  done
}

@test "sprint target: no other platform-specific SKILL.md ever went over the existing launcher word budget" {
  # Guards against the github addition silently pushing a launcher over the pre-existing
  # word cap asserted by tests/crew-afk-launcher.bats — a regression there is a regression
  # here too, just caught earlier and with more context about why.
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    words=$(wc -w < "$(afk_variant "$p")")
    [ "$words" -lt "$AFK_LAUNCHER_WORD_BUDGET" ] || { echo "$p launcher is $words words" >&2; return 1; }
  done
}
