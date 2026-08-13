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

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

words_of() {
  wc -w < "$1" | tr -d ' '
}

@test "budget: every crew-coder variant is under 1,300 words" {
  # Measured on the *installed* body — protocol.md plus the platform block — because that
  # is what a worker loads. The four source files are a few hundred words each now; the
  # thing that must stay bounded is the assembled result.
  #
  # Raised to 1,350 by the protocol extraction (the protocol is the *union* of what the
  # four bodies each said, and two of them had been missing the worked sidecar JSON the
  # other two shipped), then lowered to 1,300 when the outcome vocabulary moved to
  # solve-issue § Outcome, which owns it: crew-coder keeps only the wire format.
  for p in "${CODER_VARIANTS[@]}"; do
    words=$(words_of "$(coder_variant "$p")")
    [ "$words" -lt 1300 ] || {
      echo "$p body is $words words (budget 1300)" >&2
      return 1
    }
  done
}

@test "budget: solve-issue is under 1,600 words" {
  # Raised from 1,300 by the one-writer-per-issue-file fix: §7/§8 became a real branch on
  # "who owns the issue file", so the skill now carries two close paths where it carried
  # one. That is a new rule, not a re-explained one — the worker used to be told both to
  # tick its own acceptance criteria and never to touch the issue file, and only the
  # second half was enforced. Raised again to 1,500 when `## Outcome` arrived: the skill
  # uses `complete`/`partial`/`blocked`, so the skill defines them — they were only in
  # crew-coder, which a direct /solve-issue run never reads. The words came *from* there;
  # the chain ceiling below did not move. Raised again to 1,600 when §2's docker check
  # started running the real `detect-mode.sh` instead of re-deriving a narrower guess of
  # its own: the guess (git config OR override file) silently disagreed with what that
  # script actually decides — it also reads a Makefile `install`/`deps` target, which the
  # guess never checked — so a worktree in docker mode by that heuristic alone read as
  # host mode and never got its deps in either mode. A real new rule, not a re-explained one.
  words=$(words_of "$REPO_ROOT/skills/solve-issue/SKILL.md")
  [ "$words" -lt 1600 ] || { echo "solve-issue is $words words (budget 1600)" >&2; return 1; }
}

@test "budget: tdd is under 750 words" {
  words=$(words_of "$REPO_ROOT/skills/tdd/SKILL.md")
  [ "$words" -lt 750 ] || { echo "tdd is $words words (budget 750)" >&2; return 1; }
}

@test "budget: the whole per-issue worker chain is under 3,800 words" {
  # crew-coder + solve-issue + its verification reference + tdd. Read once per issue,
  # so this total is what a sprint multiplies by its issue count. It was 4,158 words
  # before the duplication below was cut; the ceiling leaves room for one genuinely new
  # rule, not for re-explaining an old one. Raised from 3,500 with the solve-issue
  # ceiling above, and paid for in part by crew-coder's "Issue Ownership" section, which
  # stopped restating an enforcement its own gate performs and became one line; then from
  # 3,600 with the protocol extraction, which unions four bodies into the one every
  # platform now loads. Raised from 3,700 with solve-issue's real `detect-mode.sh` call
  # (see that ceiling's own comment) — the alternative was a duplicated, drifting guess.
  total=$(words_of "$(coder_variant pi)")
  for f in "$REPO_ROOT"/skills/solve-issue/SKILL.md \
           "$REPO_ROOT"/skills/solve-issue/references/verification.md \
           "$REPO_ROOT"/skills/tdd/SKILL.md; do
    total=$((total + $(words_of "$f")))
  done
  [ "$total" -lt 3800 ] || { echo "worker chain is $total words (budget 3800)" >&2; return 1; }
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

@test "budget: the per-branch reviewer chain is under 2,210 words" {
  # Read once per branch, like the worker chain is read once per issue. The reviewer now also
  # carries the acceptance-criteria verdict, which used to be a separate agent over the same
  # diff: 2,040 words here plus a second full-diff read became 2,1xx words and one read. Worst
  # case is the protocol plus the widest reference selection a single repo can trigger
  # (quality + web-security + one framework block).
  #
  # 2,150 → 2,210 with the protocol's two machine contracts (execution evidence for the AC
  # verdict, and the `FINDING:` line that makes promotion parse one line instead of prose) —
  # see the same justification on the protocol's own budget in
  # tests/crew-code-reviewer-references.bats.
  local protocol="$REPO_ROOT/agents/crew-code-reviewer/protocol.md"
  local refs="$REPO_ROOT/agents/crew-code-reviewer/assets/references"
  local total=$(( $(words_of "$protocol") + $(words_of "$refs/quality.md") \
                  + $(words_of "$refs/web-security.md") + $(words_of "$refs/react.md") ))
  [ "$total" -lt 2210 ] || { echo "reviewer chain is $total words (budget 2210)" >&2; return 1; }
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
