#!/usr/bin/env bats

# The per-issue worker chain stays free of the duplication that once made it large.
#
# The worker chain is read once per issue, so it is the multiplier. Before the diet a
# 5-issue sprint paid ~60k tokens of scaffolding before a line of code was read, largely
# by saying the same thing twice (the PRD read, the feature-slug derivation, a step-0
# branch creation that could not fire). These tests pin that each of those stays gone.
#
# They replace per-file word-count ceilings, which parallel branches each passed alone
# and then broke together on merge, and which every coder that hit one simply raised.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

@test "the PRD is read once per issue, not once per layer" {
  # crew-coder read $MAIN_ROOT/.scratch/<slug>/PRD.md and then solve-issue §1.5 read
  # the path from the issue's Context Documents section. One file, two reads.
  chain_reads=0
  for f in "$REPO_ROOT"/agents/crew-coder/*.md \
           "$REPO_ROOT"/agents/crew-coder/codex.agent.toml; do
    grep -q 'PRD_DOC\|## Read Context Documents' "$f" && chain_reads=$((chain_reads + 1))
  done
  [ "$chain_reads" -eq 0 ] || {
    echo "$chain_reads crew-coder variant(s) still read the PRD themselves" >&2
    return 1
  }
  grep -q 'PRD' "$REPO_ROOT/skills/solve-issue/SKILL.md"
}

@test "solve-issue step 0 is a guard only: the worker is already on its branch" {
  section=$(awk '/^### 0\./{f=1;next} /^### /{f=0} f' "$REPO_ROOT/skills/solve-issue/SKILL.md")
  # The guard itself is the sole enforcement of "never commit to the default branch".
  echo "$section" | grep -q 'BLOCKED: on default branch'
  # The branch-creation call was unreachable: it only acts on the default branch, which
  # the guard above it has already refused.
  ! echo "$section" | grep -q 'feature-branch-setup\.sh'
}

@test "solve-issue does not re-assert in a checklist what its own steps just ran" {
  # Step 6 opened with four boxes restating steps 4 and 5 ("verification.md was read",
  # "every check passed"). A checkbox cannot verify itself.
  section=$(awk '/^### 6\. Commit/{f=1;next} /^### /{f=0} f' "$REPO_ROOT/skills/solve-issue/SKILL.md")
  ! echo "$section" | grep -q 'verification\.md. was read'
  # The rule that checkbox stood for still has to be somewhere: it is now one sentence.
  echo "$section" | grep -qi 'do NOT stage or commit'
}

@test "dependency install is failure-triggered, not a step every issue pays for" {
  # dep-install was invoked unconditionally: its SKILL plus one reference (800–1,250 words)
  # and a package-manager run, in worktrees that inherit node_modules via .worktreeinclude
  # and in repos with no dependency step at all. The trigger it needs already existed as
  # dep-install's own retry rule — a module-not-found on the first command that runs.
  section=$(awk '/^### 2\./{f=1;next} /^### /{f=0} f' "$REPO_ROOT/skills/solve-issue/SKILL.md")
  [ -n "$section" ]
  echo "$section" | grep -qiE 'do \*\*not\*\* install pre-emptively|only when something is missing'
  echo "$section" | grep -qiE 'module-not-found|module not found'
  # The unconditional "STOP. Read and invoke" order is gone …
  ! echo "$section" | grep -q 'STOP. Read and invoke the `dep-install` skill'
  # … but a missing skill is still a blocker rather than an improvisation, and docker mode
  # is still resolved up front, because it decides how every later command runs.
  echo "$section" | grep -q 'BLOCKED: dep-install skill not installed'
  echo "$section" | grep -q 'agent.install-mode'
}

@test "the steps that consume INSTALL_MODE still name where it came from" {
  # A mode that is only sometimes established is worse than no mode at all if the later
  # steps do not say what to assume.
  grep -q 'INSTALL_MODE from Step 2' "$REPO_ROOT/skills/solve-issue/SKILL.md"
  grep -q 'INSTALL_MODE=host' "$REPO_ROOT/skills/solve-issue/SKILL.md"
}
