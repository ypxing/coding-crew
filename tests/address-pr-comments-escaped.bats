#!/usr/bin/env bats

# address-pr-comments records each comment it fixes on a crew-afk PR as a defect crew-afk missed
# (.scratch/<slug>/reviews/escaped.md), and the reviewer eval has a template for replaying one.

load helpers/render

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$(rendered_skill address-pr-comments claude)"
}

@test "on a crew-afk PR each fixed comment is appended to escaped.md in the line format" {
  grep -qF '<!-- crew-afk:begin -->' "$SKILL"
  grep -qF 'feature/<slug>' "$SKILL"
  grep -qF '.scratch/<slug>/reviews/escaped.md' "$SKILL"
  grep -qF -- '- <YYYY-MM-DD> <file:line> — <one-line summary> — <commit sha>' "$SKILL"
  grep -qi 'append' "$SKILL"
}

@test "crew-finding comments are not recorded; a PR without the crew-afk block writes nothing" {
  grep -qF 'crew-finding:' "$SKILL"
  grep -qi 'without the crew-afk block' "$SKILL"
  grep -qi 'nothing is written' "$SKILL"
}

@test "a failed write is reported in the Summary and does not stop the skill" {
  grep -qi 'failed write' "$SKILL"
  sed -n '/^## Step 6/,/^## Unattended/p' "$SKILL" | grep -qi 'escaped'
  grep -qi 'never stops the skill' "$SKILL"
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

@test "RESULTS.md names the steps from an escaped.md line to a case" {
  r="$REPO_ROOT/scripts/eval-reviewer-misses/RESULTS.md"
  s=$(sed -n '/^## From an escaped.md line to a case/,/^## /p' "$r")
  [ -n "$s" ]
  grep -qF 'case-template.md' <<<"$s"
  grep -qF 'base_sha' <<<"$s"
  grep -qF 'Expected misses' <<<"$s"
  grep -qF -- '--dry-run' <<<"$s"
}

@test "an escaped defect is a mode: feature replay: the template defaults to it and no shipped case is a branch case" {
  d="$REPO_ROOT/scripts/eval-reviewer-misses"
  [ "$(sed -n '2p' "$d/case-template.md")" = "mode: feature" ]
  s=$(sed -n '/^## From an escaped.md line to a case/,/^## /p' "$d/RESULTS.md")
  grep -qF 'mode: feature' <<<"$s"
  grep -qF 'mode: branch` is reserved' <<<"$s"
  ! grep -lx 'mode: branch' "$d"/cases/*.md
}

@test "a crew-afk PR is one whose body has the crew-afk block; its slug comes from the slug marker, else a feature/<slug> head branch" {
  local s1; s1="$(sed -n '/^## Step 1/,/^## Step 2/p' "$SKILL")"
  grep -qF "A PR whose body has the crew-afk block" <<<"$s1"
  grep -qF '<!-- crew-afk:slug <slug> -->' <<<"$s1"
  grep -qF 'no slug marker' <<<"$s1"
  grep -qF 'feature/<slug>' <<<"$s1"
  # Steps 5 and 5.5 use that definition rather than restating a head-branch test.
  ! grep -qF 'and the head branch is `feature/<slug>`' "$SKILL"
  ! grep -qF 'branch is `feature/<slug>`. On a PR without' "$SKILL"
}
