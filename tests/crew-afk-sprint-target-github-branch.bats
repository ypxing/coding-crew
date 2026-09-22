#!/usr/bin/env bats

# Tests for issue 09 (github-issue-tracker feature): crew-afk's "Resolving the sprint
# target" step gains a github-equivalent listing alongside — not replacing — the existing
# local grep, in each of the four platform SKILL.md launcher bodies.
#
# This is prompt text, not runtime code, so the "unit test" here is a diff-based/content
# check: the pre-existing local-scan lines must survive byte-for-byte, and a new github
# branch must sit alongside them, consistently across all four platforms.

load helpers/render

LOCAL_LS_LINE='ls -d .scratch/*/ 2>/dev/null'
LOCAL_GREP_LINE='grep -rl "Status: ready-for-agent" .scratch/*/issues/open/*.md 2>/dev/null'

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

@test "sprint target: the existing local ls line is untouched in every platform variant" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    [[ "$fence" == *"$LOCAL_LS_LINE"* ]] || {
      echo "$p: local ls line missing or modified" >&2; return 1; }
  done
}

@test "sprint target: the existing local grep line is untouched, immediately after the ls line" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    [[ "$fence" == *"$LOCAL_LS_LINE"$'\n'"$LOCAL_GREP_LINE"* ]] || {
      echo "$p: the two local lines are no longer adjacent/unmodified as a pair" >&2; return 1; }
  done
}

@test "sprint target: each platform gains a github-tracker conditional branch, alongside the local lines" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    [[ "$fence" == *"tracker: github"* ]] || {
      echo "$p: no mention of tracker: github" >&2; return 1; }
  done
}

@test "sprint target: each platform's github branch runs the milestone-scoped ready-for-agent listing" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    fence="$(sprint_target_fence "$p")"
    [[ "$fence" == *"gh issue list"* ]] || {
      echo "$p: no gh issue list invocation" >&2; return 1; }
    [[ "$fence" == *"--milestone"* ]] || {
      echo "$p: gh issue list is missing --milestone" >&2; return 1; }
    [[ "$fence" == *"--label ready-for-agent"* ]] || {
      echo "$p: gh issue list is missing --label ready-for-agent" >&2; return 1; }
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

@test "sprint target: no other platform-specific SKILL.md ever went over the existing 500-word launcher budget" {
  # Guards against the github addition silently pushing a launcher over the pre-existing
  # word cap asserted by tests/crew-afk-launcher.bats — a regression there is a regression
  # here too, just caught earlier and with more context about why.
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    words=$(wc -w < "$(afk_variant "$p")")
    [ "$words" -lt 500 ] || { echo "$p launcher is $words words" >&2; return 1; }
  done
}
