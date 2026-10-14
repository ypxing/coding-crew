#!/usr/bin/env bats

# CLAUDE.md's layer-ownership table, asserted. The call direction is solve-feature → solve-issue
# (skill) → tdd / dep-install; a human running /solve-issue gets the same procedure:
#
#   | layer           | owns                                           | must not contain        |
#   | solve-issue     | the ordered procedure + the outcome vocabulary | who its caller is       |
#   | tdd/dep-install | one technique each                             | issue/report/status     |
#
# Anything that fits no row is in the wrong file. These tests are that table.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SOLVE_ISSUE="$REPO_ROOT/skills/solve-issue/SKILL.md"
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

@test "solve-issue stops on what no repo file can provide, once, with the command as evidence" {
  # A coder hit "License activation failed" six minutes in, then spent 21 more hand-starting
  # compose services, and reported partial. The rule is the procedure's, so a direct
  # /solve-issue run gets it too — and it names no caller.
  section=$(awk '/^## Outcome/{f=1;next} /^## /{f=0} f' "$SOLVE_ISSUE")
  echo "$section" | grep -q 'no file in this repo can provide'
  echo "$section" | grep -q '\*\*once\*\*'
  echo "$section" | grep -q 'its exit code and its verbatim'
  echo "$section" | grep -q 'Do not start services by hand, search for tokens'
  echo "$section" | grep -qF '$ <command> (exit <N>)'
  ! echo "$section" | grep -qiE 'solve-feature|triage|orchestrat'
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
  for name in 'solve-feature' 'crew-coder' 'the orchestrator' 'An orchestrator' 'crew-afk'; do
    ! grep -qF "$name" "$SOLVE_ISSUE" || {
      echo "solve-issue still names its caller: $name" >&2
      grep -nF "$name" "$SOLVE_ISSUE" >&2
      return 1; }
  done
}

@test "the non-interactive branch fires on the capability check, not on caller identity" {
  section=$(awk '/^### 8\./{f=1} /^## /{if(f)exit} f' "$SOLVE_ISSUE")
  echo "$section" | grep -qi 'non-interactive'
  echo "$section" | grep -qi 'partial'
  # The retired form: "your instructions name an orchestrator as your caller".
  ! echo "$section" | grep -qi 'name an orchestrator\|your caller'
}

@test "the blocked-by check no longer explains who filters issues" {
  section=$(awk '/^### 1\./{f=1} /^### 1\.5/{exit} f' "$SOLVE_ISSUE")
  ! echo "$section" | grep -qi 'orchestrator'
}

# ─── the environment contract is stated once ─────────────────────────────────

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

# ─── a direct run is self-sufficient ─────────────────────────────────────────

@test "solve-issue keeps its branch guard" {
  grep -q '^### 0\. Branch guard' "$SOLVE_ISSUE"
  grep -q 'DEFAULT_BRANCH' "$SOLVE_ISSUE"
}

# ─── the table is written down where the next change will look ───────────────

@test "CLAUDE.md records the ownership table, with no orchestrator, crew-afk scripts or crew-coder row" {
  local f="$REPO_ROOT/CLAUDE.md"
  grep -q 'Layer ownership\|ownership table' "$f"
  # Every layer named, with a "must not contain" column.
  grep -q 'Must not contain' "$f"
  for layer in 'solve-feature' 'solve-issue' 'tdd' 'dep-install'; do
    grep -q "$layer" "$f" || { echo "CLAUDE.md's table omits $layer" >&2; return 1; }
  done
  ! grep -qE '^\| `((orchestrator|skills/crew-afk/scripts)/|crew-coder)`' "$f"
}

