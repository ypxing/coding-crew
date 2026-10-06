#!/usr/bin/env bats

# On a crew-afk PR, /address-pr-comments pushes its fix commit once the local checks pass, and says
# when the PR can leave draft. Every other PR keeps "Do not push"; --auto keeps push-rework.sh.

load helpers/render

setup() {
  SKILL="$(rendered_skill address-pr-comments claude)"
  STEP5="$(sed -n '/^## Step 5 — Commit/,/^## Step 5.5/p' "$SKILL")"
}

@test "on a crew-afk PR Step 5 runs solve-issue's run-checks.sh after the commit, then a plain git push only on CHECKS: pass" {
  grep -qF '<!-- crew-afk:begin -->' <<<"$STEP5"
  grep -qF 'feature/<slug>' <<<"$STEP5"
  grep -qF '../solve-issue/scripts/run-checks.sh' <<<"$STEP5"
  grep -qF 'CHECKS: pass' <<<"$STEP5"
  grep -qF 'git push' <<<"$STEP5"
  grep -qi 'never forced' <<<"$STEP5"
  ! grep -qE 'push (-f|--force)' <<<"$STEP5"
  grep -qi 'show the failing output' <<<"$STEP5"
  grep -qi 'do not push' <<<"$STEP5"
}

@test "any other PR still is not pushed, and --auto still pushes only through push-rework.sh" {
  grep -qF 'On any other PR, do not push' <<<"$STEP5"
  sed -n '/^## Unattended mode/,/^---/p' "$SKILL" | grep -qF 'push-rework.sh'
  sed -n '/^## Unattended mode/,/^---/p' "$SKILL" | grep -qF 'not the crew-afk push'
}

@test "the summary suggests gh pr ready only after a push, when findings is the only draft reason and every crew-finding comment was handled" {
  local s; s="$(sed -n '/^## Step 6/,/^## Unattended/p' "$SKILL")"
  grep -qF 'once CI is green: gh pr ready <n>' <<<"$s"
  grep -qF '<!-- crew-afk:draft' <<<"$s"
  grep -qF 'names `findings` and nothing else' <<<"$s"
  grep -qF 'crew-finding:' <<<"$s"
  grep -qi 'handled this run' <<<"$s"
  grep -qi 'never runs `gh pr ready`' "$SKILL"
  grep -qi 'never waits on CI' "$SKILL"
}

@test "the docs describe the closing review and the push on crew-afk PRs" {
  local root; root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  for f in README.md docs/guide.md .claude/rules/crew-afk.md orchestrator/lib/loop.mjs; do
    grep -qi 'closing review' "$root/$f" || { echo "$f: no closing review"; return 1; }
  done
  for f in README.md docs/guide.md .claude/rules/crew-afk.md; do
    grep -q 'address-pr-comments' "$root/$f" && grep -qi 'push' "$root/$f" || { echo "$f: no push"; return 1; }
  done
}
