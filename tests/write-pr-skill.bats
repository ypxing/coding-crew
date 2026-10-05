#!/usr/bin/env bats

# The write-pr body a reviewer gets: a short Why / What changes / Risk / Tested note — the
# shape crew-afk's PR writer follows too (orchestrator/lib/pipeline/pr-body.mjs keys on `## Why`).

load helpers/render

@test "write-pr: the installed template is Why / What changes / Risk / Tested, with no Evidence or Merge Danger" {
  local f
  f="$(rendered_skill write-pr claude)"
  grep -q '^## Why$' "$f"
  grep -q '^## What changes$' "$f"
  grep -q '^## Risk$' "$f"
  grep -q '^\*\*Tested:\*\*' "$f"
  ! grep -q '## Evidence' "$f"
  ! grep -q '## Merge Danger' "$f"
}

@test "write-pr: registry.json's description names the same sections" {
  local d
  d="$(jq -r '.skills["write-pr"].description' "$RENDER_HELPER_REPO_ROOT/registry.json")"
  [[ "$d" == *Why* && "$d" == *"What changes"* && "$d" == *Risk* && "$d" == *Tested* ]]
  [[ "$d" != *"Merge Danger"* && "$d" != *Evidence* ]]
}
