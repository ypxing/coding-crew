#!/usr/bin/env bats

# Budgets for the prompt text a crew sprint loads **per issue**.
#
# The orchestrator body is read once per sprint; the worker chain is read once per
# issue, so it is the multiplier. Before the diet a 5-issue sprint paid ~60k tokens of
# scaffolding before a line of code was read, and the chain below accounted for most
# of it — largely by saying the same thing twice (the PRD read, the feature-slug
# derivation, two worked examples, a phase-level trace that cost ~10 round trips a
# worker, and a step-0 branch creation that could not fire).
#
# A budget is the only thing that stops that creeping back as prose. These are ceilings
# with headroom, not targets: a real new rule fits, a re-explained old one does not.
# When a budget is genuinely too tight, raise it in the same commit that earns it and
# say why.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

words_of() {
  wc -w < "$1" | tr -d ' '
}

@test "budget: every crew-coder variant is under 1,250 words" {
  for f in "$REPO_ROOT"/agents/crew-coder/claude.agent.md \
           "$REPO_ROOT"/agents/crew-coder/pi.agent.md \
           "$REPO_ROOT"/agents/crew-coder/copilot.agent.md \
           "$REPO_ROOT"/agents/crew-coder/codex.agent.toml; do
    words=$(words_of "$f")
    [ "$words" -lt 1250 ] || {
      echo "$(basename "$f") is $words words (budget 1250)" >&2
      return 1
    }
  done
}

@test "budget: solve-issue is under 1,300 words" {
  words=$(words_of "$REPO_ROOT/skills/solve-issue/SKILL.md")
  [ "$words" -lt 1300 ] || { echo "solve-issue is $words words (budget 1300)" >&2; return 1; }
}

@test "budget: tdd is under 750 words" {
  words=$(words_of "$REPO_ROOT/skills/tdd/SKILL.md")
  [ "$words" -lt 750 ] || { echo "tdd is $words words (budget 750)" >&2; return 1; }
}

@test "budget: the whole per-issue worker chain is under 3,500 words" {
  # crew-coder + solve-issue + its verification reference + tdd. Read once per issue,
  # so this total is what a sprint multiplies by its issue count. It was 4,158 words
  # before the duplication below was cut; the ceiling leaves room for one genuinely new
  # rule, not for re-explaining an old one.
  total=0
  for f in "$REPO_ROOT"/agents/crew-coder/pi.agent.md \
           "$REPO_ROOT"/skills/solve-issue/SKILL.md \
           "$REPO_ROOT"/skills/solve-issue/references/verification.md \
           "$REPO_ROOT"/skills/tdd/SKILL.md; do
    total=$((total + $(words_of "$f")))
  done
  [ "$total" -lt 3500 ] || { echo "worker chain is $total words (budget 3500)" >&2; return 1; }
}

# ─── and the duplication that made it large stays gone ───────────────────────

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
