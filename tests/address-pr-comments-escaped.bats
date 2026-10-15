#!/usr/bin/env bats

# address-pr-comments records each comment it fixes on a solve-feature PR as a defect its review missed
# (.scratch/<slug>/reviews/escaped.md), and the reviewer eval has a template for replaying one.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "the eval has a case template, outside cases/, that parses" {
  t="$REPO_ROOT/scripts/eval-reviewer-misses/case-template.md"
  [ -s "$t" ]
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" T="$t" node -e '
    import(process.env.MOD).then((m) => {
      const c = m.parseCase("template", require("fs").readFileSync(process.env.T, "utf8"));
      if (!c.misses.length || !c.reference || !c.prd || !c.criteria) throw new Error("template incomplete");
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
}

@test "an escaped defect is a mode: feature replay: the template defaults to it and no shipped case is a branch case" {
  d="$REPO_ROOT/scripts/eval-reviewer-misses"
  [ "$(sed -n '2p' "$d/case-template.md")" = "mode: feature" ]
  ! grep -lx 'mode: branch' "$d"/cases/*.md
}

@test "address-pr-comments reads a solve-feature PR's slug from its body, so Step 1 does not fetch the head branch" {
  ! grep -n 'headRefName' "$REPO_ROOT/skills/address-pr-comments/SKILL.md"
}
