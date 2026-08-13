#!/usr/bin/env bats

# The layer-ownership table from .scratch/coder-boundary/PRD.md, asserted.
#
# The call direction is right — crew-afk (program) → crew-coder (agent) → solve-issue
# (skill) → tdd / dep-install — but crew-coder is on the *sprint path only*. A human
# running /solve-issue never touches it; their own session plays the coder role. So every
# piece of "coder role" content that lived in crew-coder was missing from the direct path
# and duplicated on the sprint path:
#
#   | layer        | owns                                          | must not contain      |
#   | crew-coder   | tool/model bindings, env binding, report wire  | the implementation loop |
#   | solve-issue  | the ordered procedure + the outcome vocabulary | who its caller is       |
#   | tdd/dep-install | one technique each                         | issue/report/status     |
#
# Anything that fits no row is in the wrong file. These tests are that table.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SOLVE_ISSUE="$REPO_ROOT/skills/solve-issue/SKILL.md"
PROTOCOL="$REPO_ROOT/agents/crew-coder/protocol.md"
HOST_INSTALL="$REPO_ROOT/skills/dep-install/references/host-install.md"
TDD="$REPO_ROOT/skills/tdd/SKILL.md"

# A "definition" of a term is a bullet that explains what it means, not a use of it.
# `- **`complete`** — all acceptance criteria met...` defines; "report status `complete`" uses.
defines_term() {
  local file="$1" term="$2"
  grep -qE "^[[:space:]]*[-*][[:space:]]+\*\*.?${term}.?\*\*[[:space:]]*(—|-|:)" "$file"
}

# ─── the outcome vocabulary belongs to the procedure ──────────────────────────

@test "solve-issue has an ## Outcome section" {
  grep -q '^## Outcome' "$SOLVE_ISSUE"
}

@test "solve-issue defines all three outcome words" {
  for term in complete partial blocked; do
    defines_term "$SOLVE_ISSUE" "$term" || {
      echo "solve-issue does not define '$term'" >&2; return 1; }
  done
}

@test "solve-issue defines the BLOCKED: line format" {
  section=$(awk '/^## Outcome/{f=1;next} /^## /{f=0} f' "$SOLVE_ISSUE")
  echo "$section" | grep -q 'BLOCKED:'
}

@test "solve-issue is the only place the three outcome words are defined" {
  # crew-coder used to define them, so a direct invocation ran with an undefined
  # vocabulary while the sprint path got two copies.
  for term in complete partial blocked; do
    ! defines_term "$PROTOCOL" "$term" || {
      echo "crew-coder's protocol still defines '$term' — solve-issue owns it" >&2; return 1; }
  done
}

@test "crew-coder's report section defines the transport and nothing more" {
  # What it genuinely owns: where the result goes, what the fields are called, and when.
  grep -q 'report.json' "$PROTOCOL"
  grep -q 'as your last action' "$PROTOCOL"
  grep -q '"status"' "$PROTOCOL"
  grep -q '"progress"' "$PROTOCOL"
  # ...and it points at the procedure for what the words mean, rather than restating them.
  grep -q 'solve-issue' "$PROTOCOL"
}

@test "every rendered coder body still carries the wire format" {
  # Reducing crew-coder to transport must not lose the transport.
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    grep -qF 'report.json' "$f"
    grep -qF 'as your last action' "$f"
    for field in status branch working_directory checks criteria progress notes; do
      grep -qF "\"$field\"" "$f" || { echo "$p lost field $field" >&2; return 1; }
    done
  done
}

@test "tdd and dep-install carry no issue, report or status concepts" {
  # One technique each: the row that keeps the vocabulary from spreading a third time.
  for term in complete partial; do
    ! defines_term "$TDD" "$term" || { echo "tdd defines '$term'" >&2; return 1; }
    ! defines_term "$HOST_INSTALL" "$term" || { echo "host-install defines '$term'" >&2; return 1; }
  done
  ! grep -q 'report\.json' "$TDD"
  ! grep -q 'report\.json' "$HOST_INSTALL"
}

# ─── the procedure does not know its caller ──────────────────────────────────

@test "solve-issue names no caller as an actor" {
  # A procedure that describes its caller by name is wrong the moment a second caller
  # exists. Every such branch must be a capability check instead.
  for name in 'crew-coder' 'crew worker' 'the orchestrator' 'An orchestrator' 'crew-afk'; do
    ! grep -qF "$name" "$SOLVE_ISSUE" || {
      echo "solve-issue still names its caller: $name" >&2
      grep -nF "$name" "$SOLVE_ISSUE" >&2
      return 1; }
  done
}

@test "solve-issue branches on capabilities, not identities" {
  # The facts it is allowed to test: the orchestration marker, the env var, a worktree.
  grep -q 'CREW_ORCHESTRATED' "$SOLVE_ISSUE"
  grep -q '\.orchestrated' "$SOLVE_ISSUE"
}

@test "the non-interactive branch fires on the capability check, not on caller identity" {
  section=$(awk '/^### 8\./{f=1} /^## /{if(f)exit} f' "$SOLVE_ISSUE")
  echo "$section" | grep -qi 'non-interactive'
  echo "$section" | grep -q 'CREW_ORCHESTRATED'
  echo "$section" | grep -qi 'partial'
  # The retired form: "your instructions name an orchestrator as your caller".
  ! echo "$section" | grep -qi 'name an orchestrator\|your caller'
}

@test "the blocked-by check no longer explains who filters issues" {
  section=$(awk '/^### 1\./{f=1} /^### 1\.5/{exit} f' "$SOLVE_ISSUE")
  ! echo "$section" | grep -qi 'orchestrator'
}

# ─── the environment contract is stated once ─────────────────────────────────

@test "MAIN_ROOT and PROJECT_ROOT are defined in exactly one place" {
  local definers=0
  for f in "$PROTOCOL" "$SOLVE_ISSUE" "$HOST_INSTALL"; do
    if defines_term "$f" 'MAIN_ROOT'; then
      definers=$((definers + 1))
      [ "$f" = "$PROTOCOL" ] || {
        echo "$f defines MAIN_ROOT — crew-coder binds it, everyone else references it" >&2
        return 1; }
    fi
  done
  [ "$definers" -eq 1 ] || { echo "MAIN_ROOT is defined in $definers places, want 1" >&2; return 1; }
}

@test "solve-issue and host-install reference the variables without redefining them" {
  for f in "$SOLVE_ISSUE" "$HOST_INSTALL"; do
    grep -q 'MAIN_ROOT' "$f"
    grep -qi 'do not re-derive\|inherited' "$f" || {
      echo "$f neither inherits nor references: it must say where they come from" >&2
      return 1; }
    # No second description of what they are.
    ! defines_term "$f" 'PROJECT_ROOT' || {
      echo "$f redefines PROJECT_ROOT" >&2; return 1; }
  done
}

@test "the orchestrator is the only thing that emits them" {
  # prompts.mjs is the one place the values are produced; crew-coder binds what it emits.
  grep -q 'MAIN_ROOT=' "$REPO_ROOT/orchestrator/lib/prompts.mjs"
  grep -q 'Working directory' "$REPO_ROOT/orchestrator/lib/prompts.mjs"
  grep -q 'Working directory' "$PROTOCOL"
}

# ─── a direct run is self-sufficient ─────────────────────────────────────────

@test "nothing in solve-issue depends on a definition only crew-coder has" {
  # The three outcome words are used in the skill, so the skill must define them.
  grep -q 'partial' "$SOLVE_ISSUE"
  grep -q '^## Outcome' "$SOLVE_ISSUE"
  # And its two variables must be named as inherited, so a human can set them.
  grep -qi 'inherited' "$SOLVE_ISSUE"
}

@test "solve-issue keeps the accepted redundancies finding 7 recorded" {
  # The branch guard is redundant inside a sprint but correct and cheap for a direct run.
  grep -q '^### 0\. Branch guard' "$SOLVE_ISSUE"
  grep -q 'DEFAULT_BRANCH' "$SOLVE_ISSUE"
}

# ─── the table is written down where the next change will look ───────────────

@test "CLAUDE.md records the ownership table" {
  local f="$REPO_ROOT/CLAUDE.md"
  grep -q 'Layer ownership\|ownership table' "$f"
  # Every layer named, with a "must not contain" column.
  grep -q 'Must not contain' "$f"
  for layer in 'crew-coder' 'solve-issue' 'orchestrator' 'tdd'; do
    grep -q "$layer" "$f" || { echo "CLAUDE.md's table omits $layer" >&2; return 1; }
  done
}
