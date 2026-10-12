#!/usr/bin/env bats

# The feature branch's name is configurable (`afk.branchPrefix`, `--jira`), so no prompt text may
# name a `feature/<…>` branch format: an agent reading it would derive a slug from a branch name
# that no longer has that shape. Scripts that build the branch (`.sh`, `.mjs`) are not prompt text.

load helpers/render
load helpers/platforms

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  T="$(mktemp -d)"
}
teardown() { rm -rf "$T"; }

# scan_prompt_files <root> — prints each prompt .md under <root> that contains `feature/<`, as
# `<path relative to root>: <line>`; exits 1 when any does.
scan_prompt_files() {
  local root="$1" hits
  hits=$(cd "$root" && {
    find orchestrator/roles -type f -name '*.md'
    find skills/_shared/fragments -maxdepth 1 -type f -name '*.md'
    find skills -mindepth 3 -maxdepth 3 -path 'skills/*/references/*.md' -type f
  } 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    grep -n -F 'feature/<' "$f" | sed "s|^|$f: |"
  done)
  [ -z "$hits" ] || { printf '%s\n' "$hits"; return 1; }
}

@test "no rendered skill body names the feature/<…> branch format, on any platform" {
  local skill platform body fails=""
  for skill in $(jq -r '.skills | keys[]' "$REPO_ROOT/registry.json" | tr -d '\r'); do
    for platform in "${PLATFORMS[@]}"; do
      body=$(rendered_skill "$skill" "$platform")
      grep -q -F 'feature/<' "$body" && fails+="$skill ($platform)"$'\n'
    done
  done
  [ -z "$fails" ] || { printf 'feature/< in rendered skill:\n%s' "$fails"; return 1; }
}

@test "no role protocol, shared fragment or skill reference names the feature/<…> branch format" {
  run scan_prompt_files "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the file scan fails naming the file that names feature/<slug>" {
  mkdir -p "$T/orchestrator/roles/reviewer/references" "$T/skills/_shared/fragments" "$T/skills/tdd/references"
  cp "$REPO_ROOT/orchestrator/roles/reviewer/references/backend.md" "$T/orchestrator/roles/reviewer/references/"
  cp "$REPO_ROOT/skills/_shared/fragments/findings-rubric.md" "$T/skills/_shared/fragments/"
  cp "$REPO_ROOT/skills/tdd/references/mocking.md" "$T/skills/tdd/references/"
  run scan_prompt_files "$T"
  [ "$status" -eq 0 ]

  for f in orchestrator/roles/reviewer/references/backend.md skills/_shared/fragments/findings-rubric.md \
           skills/tdd/references/mocking.md; do
    cp "$T/$f" "$T/$f.orig"
    echo 'Take <slug> from a `feature/<slug>` head branch.' >> "$T/$f"
    run scan_prompt_files "$T"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$f: "* ]] || { echo "$output"; return 1; }
    mv "$T/$f.orig" "$T/$f"
  done
}
