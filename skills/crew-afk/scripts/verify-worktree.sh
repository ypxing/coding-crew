#!/usr/bin/env bash
set -uo pipefail

# verify-worktree.sh — run project checks in a worktree directory
#
# Usage: verify-worktree.sh --dir <worktree-path>
#
# Discovers check commands using the same verification reference chain as
# skills/solve-issue/references/verification.md:
#   1. CLAUDE.md at the worktree root (explicit Run: commands under Tests section)
#   2. Makefile targets (test, lint, typecheck)
#   3. Ecosystem conventions (bats, npm test, pytest, cargo test, go test, etc.)
#
# A check category with no discoverable command is reported explicitly as
# not_run — never silently treated as passing.
#
# Exit code: 0 if all discovered checks pass, non-zero otherwise.

WORKTREE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      WORKTREE_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 --dir <worktree-path>" >&2
      exit 1
      ;;
  esac
done

if [ -z "$WORKTREE_DIR" ]; then
  echo "ERROR: --dir <worktree-path> is required" >&2
  exit 1
fi

if [ ! -d "$WORKTREE_DIR" ]; then
  echo "ERROR: directory does not exist: $WORKTREE_DIR" >&2
  exit 1
fi

# ─── check discovery ─────────────────────────────────────────────────────────

# _discover_from_claude_md <category> <worktree-dir>
# Looks for a "Run: `command`" line under a ## <category> section in CLAUDE.md.
# Prints the command if found, empty string otherwise.
_discover_from_claude_md() {
  local category="$1"
  local dir="$2"
  local claude_md="$dir/CLAUDE.md"

  if [ ! -f "$claude_md" ]; then
    echo ""
    return
  fi

  # Find sections matching the category header, then look for Run: lines
  # Use grep/sed: find lines after a matching ## header until the next ## header
  local in_section=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^## ]]; then
      if echo "$line" | grep -qi "$category"; then
        in_section=1
      else
        in_section=0
      fi
    elif [[ "$in_section" -eq 1 ]] && echo "$line" | grep -q "Run:"; then
      # Extract content between backticks
      local extracted
      extracted=$(echo "$line" | sed "s/.*\`\([^\`]*\)\`.*/\1/")
      if [ "$extracted" != "$line" ] && [ -n "$extracted" ]; then
        echo "$extracted"
        return
      fi
    fi
  done < "$claude_md"
}

# _has_makefile_target <target> <worktree-dir>
# Returns 0 if the Makefile has the specified target, non-zero otherwise.
_has_makefile_target() {
  local target="$1"
  local dir="$2"
  local makefile="$dir/Makefile"

  if [ ! -f "$makefile" ]; then
    return 1
  fi

  grep -qE "^${target}[[:space:]]*:" "$makefile"
}

# _discover_test_command <worktree-dir>
# Returns the test command or empty string if none found.
#
# Every command returned here is executed under `cd "$WORKTREE_DIR"` (see the
# run section below), so a command needs no path argument to be correct. Where
# one is embedded anyway (make -C, bats, cargo --manifest-path) it is
# belt-and-braces; where it is absent (go test ./...) the cd is what makes it
# right. Do not run a returned command outside that subshell.
_discover_test_command() {
  local dir="$1"

  # 1. CLAUDE.md explicit command under Tests section
  local cmd
  cmd=$(_discover_from_claude_md "test" "$dir")
  if [ -n "$cmd" ]; then
    echo "$cmd"
    return
  fi

  # 2. Makefile test target
  if _has_makefile_target "test" "$dir"; then
    echo "make -C \"$dir\" test"
    return
  fi

  # 3. Ecosystem conventions
  # bats: point bats at the directory the .bats files are actually in — a repo
  # with root-level .bats files and no tests/ dir must not be handed tests/.
  if ls "$dir"/tests/*.bats >/dev/null 2>&1; then
    echo "bats \"$dir\"/tests/"
    return
  fi
  if ls "$dir"/*.bats >/dev/null 2>&1; then
    echo "bats \"$dir\""
    return
  fi

  # npm/pnpm/yarn: package.json with test script
  if [ -f "$dir/package.json" ] && grep -q '"test"' "$dir/package.json" 2>/dev/null; then
    echo "npm test --prefix \"$dir\""
    return
  fi

  # Python: pytest
  if ls "$dir"/*.py >/dev/null 2>&1 || ls "$dir"/tests/*.py >/dev/null 2>&1; then
    echo "pytest \"$dir\""
    return
  fi

  # Go: go test
  if [ -f "$dir/go.mod" ]; then
    echo "go test ./..."
    return
  fi

  # Rust: cargo test
  if [ -f "$dir/Cargo.toml" ]; then
    echo "cargo test --manifest-path \"$dir/Cargo.toml\""
    return
  fi

  # Ruby: bundle exec rspec
  # No path flag: rspec has no --project-root, and the cd below already sets cwd.
  if [ -f "$dir/Gemfile" ]; then
    echo "bundle exec rspec"
    return
  fi

  echo ""
}

# ─── run checks ──────────────────────────────────────────────────────────────

OVERALL_EXIT=0

echo "Verifying worktree: $WORKTREE_DIR"
echo ""

# Discover and run test command
TEST_CMD=$(_discover_test_command "$WORKTREE_DIR")

if [ -z "$TEST_CMD" ]; then
  echo "TEST: not_run — no command found (checked CLAUDE.md, Makefile, and ecosystem conventions)"
  OVERALL_EXIT=1
else
  echo "TEST: running: $TEST_CMD"
  # Run in the worktree directory so relative paths resolve correctly
  if (cd "$WORKTREE_DIR" && eval "$TEST_CMD") 2>&1; then
    echo "TEST: pass"
  else
    echo "TEST: fail"
    OVERALL_EXIT=1
  fi
fi

echo ""
if [ "$OVERALL_EXIT" -eq 0 ]; then
  echo "Verification: success — all checks pass"
else
  echo "Verification: fail — one or more checks did not pass"
fi

exit "$OVERALL_EXIT"
