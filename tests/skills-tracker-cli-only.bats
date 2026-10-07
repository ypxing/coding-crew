#!/usr/bin/env bats

# Skills reach the tracker only through the tracker CLI (`tracker/cli.mjs`, PRD #328 D1, D9–D12,
# B6): no rendered tracker-touching skill runs `gh` itself or branches on the tracker, the shared
# tracker-configuration fragment is the one place that says how to call the CLI, and the tracker
# templates list CLI commands for a person instead of prose operations. Asserted against the
# rendered output, for every platform — what a consuming repo receives.

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
TRACKER_SKILLS=(to-issues to-prd crew-address-findings upgrade-deps solve-issue)

# The `## Tracker Configuration` section of a rendered body.
tracker_section() {
  awk '/^## Tracker Configuration$/{f=1;print;next} f&&/^## /{exit} f' "$1"
}

@test "no rendered tracker-touching skill runs gh or branches on the tracker, for every platform" {
  local skill p f
  for skill in "${TRACKER_SKILLS[@]}"; do
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      if grep -nF '`gh ' "$f"; then echo "$skill/$p runs gh" >&2; return 1; fi
      if grep -niE 'under (a |the )?(configured )?`(github|local)`' "$f"; then
        echo "$skill/$p branches on the tracker" >&2; return 1
      fi
      if grep -nF '{{FRAGMENT' "$f"; then echo "$skill/$p left a fragment unexpanded" >&2; return 1; fi
    done
  done
}

@test "the tracker-configuration fragment checks node first, names the CLI with its \$HOME fallback, and forbids working around a failure, for every platform" {
  local skill p f section node_line op_line
  for skill in "${TRACKER_SKILLS[@]}"; do
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      section=$(tracker_section "$f")
      [ -n "$section" ] || { echo "$skill/$p has no Tracker Configuration section" >&2; return 1; }
      grep -qF 'node --version' <<<"$section"
      grep -qF 'the tracker CLI needs Node' <<<"$section"
      grep -qF '"$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs"' <<<"$section"
      grep -qF '"$HOME/.coding-crew/tracker/cli.mjs"' <<<"$section"
      grep -qiF 'fix its cause' <<<"$section"
      grep -qF "never perform the operation with the tracker's own tool" <<<"$section"
      node_line=$(grep -nF 'node --version' <<<"$section" | head -1 | cut -d: -f1)
      op_line=$(grep -nF 'node "$TRACKER"' <<<"$section" | head -1 | cut -d: -f1)
      [ -n "$op_line" ] && [ "$node_line" -lt "$op_line" ]
    done
  done
}

@test "solve-issue includes the fragment and fetches and marks done through the CLI" {
  grep -qF '{{FRAGMENT:tracker-configuration}}' "$REPO_ROOT/skills/solve-issue/SKILL.md"
  local p f
  for p in "${PLATFORMS[@]}"; do
    f=$(rendered_skill solve-issue "$p")
    grep -qF 'node "$TRACKER" fetch <issue-ref>' "$f"
    grep -qF 'node "$TRACKER" mark-done <issue-ref>' "$f"
    ! grep -qF 'operation from `issue-tracker.md`' "$f"
  done
}

@test "to-issues drafts, lints against known, publishes through publish-issues and rewrites through rewrite, for every platform" {
  local p f
  for p in "${PLATFORMS[@]}"; do
    f=$(rendered_skill to-issues "$p")
    grep -qF 'node "$TRACKER" fetch <ref> --comments' "$f"
    grep -qF 'node "$TRACKER" prd --feature-slug <feature-slug>' "$f"
    grep -qF 'node "$TRACKER" known --feature-slug <feature-slug> --out .scratch/<feature-slug>/.drafts/known' "$f"
    grep -qF -- '--deps .scratch/<feature-slug>/.drafts/deps.json' "$f"
    grep -qF -- '--known <file>' "$f"
    grep -qF 'node "$TRACKER" publish-issues --feature-slug <feature-slug> --drafts .scratch/<feature-slug>/.drafts' "$f"
    grep -qE '^- \*\*Exit 4\*\*.*stop.*Some issues are already completed' "$f"
    grep -qE '^- \*\*Exit 5\*\*.*overwritten.*confirmation.*--replace' "$f"
    grep -qF 'node "$TRACKER" rewrite <ref> --body-file <file> --status <status> --feature-slug <feature-slug>' "$f"
    # One draft set for every tracker: deps.json is written whatever the tracker is.
    ! grep -qiF 'local tracker only' "$f"
    ! grep -qF 'issues-deps.json' "$f"
  done
}

@test "to-prd publishes through publish-prd, crew-address-findings reads the PRD through prd, upgrade-deps names to-issues' write step, for every platform" {
  local p
  for p in "${PLATFORMS[@]}"; do
    grep -qF 'node "$TRACKER" publish-prd --feature-slug <feature-slug> --title "<feature title>" --body-file <file>' "$(rendered_skill to-prd "$p")"
    grep -qF 'node "$TRACKER" prd --feature-slug <feature-slug>' "$(rendered_skill crew-address-findings "$p")"
    grep -qF "the ref \`promote-findings.sh\` prints" "$(rendered_skill crew-address-findings "$p")"
    grep -qF "\`to-issues\`' step 6 (\"Write the issues\")" "$(rendered_skill upgrade-deps "$p")"
    ! grep -qiE 'github|issues-deps\.json' <(awk '/^### 8\. Publish/{f=1;next} /^### /{f=0} f' "$(rendered_skill upgrade-deps "$p")")
  done
}

@test "to-issues' rerun and github-publish references are gone and no rendered skill names them" {
  [ ! -e "$REPO_ROOT/skills/to-issues/references/rerun.md" ]
  [ ! -e "$REPO_ROOT/skills/to-issues/references/github-publish.md" ]
  local skill p
  for skill in "${TRACKER_SKILLS[@]}" crew-afk; do
    for p in "${PLATFORMS[@]}"; do
      ! grep -qE 'rerun\.md|github-publish\.md' "$(rendered_skill "$skill" "$p")"
    done
  done
}

@test "crew-afk's target lookup comment runs no gh" {
  ! grep -qE '#.*gh issue list' "$REPO_ROOT/skills/crew-afk/SKILL.md"
}

@test "the tracker templates have no Operation sections, list the CLI commands, and fix the label strings" {
  local t
  for t in local github; do
    t="$REPO_ROOT/docs/templates/trackers/$t.md"
    ! grep -q '^## Operation:' "$t"
    grep -q '^## Tracker CLI' "$t"
    for op in fetch prd known publish-issues publish-prd rewrite mark-done; do
      grep -qE "^node \"\\\$TRACKER\" $op( |$)" "$t" || { echo "$t lacks the $op command" >&2; return 1; }
    done
  done
  ! grep -qF 'Edit the right-hand column' "$REPO_ROOT/docs/templates/trackers/local.md"
}
