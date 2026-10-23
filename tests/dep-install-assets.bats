#!/usr/bin/env bats

# dep-install's scripts are the checks library (lib/checks): committed as a link to ../../../lib/checks at
# skills/coding-crew-lib/scripts/checks, copied through it at install into the coding-crew-lib skill every skill
# that runs it depends on, so the skill text's "<skill-dir>/../coding-crew-lib/scripts/checks/<script>" runs.

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

fresh_target() {
  local target="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$target"
  git -C "$target" init -q -b main
  printf '%s\n' "$target"
}

LIB=".pi/skills/coding-crew-lib/scripts/checks"

@test "dep-install, solve-issue, solve-feature and address-pr-comments depend on coding-crew-lib" {
  local s
  for s in dep-install solve-issue solve-feature address-pr-comments; do
    run jq -r --arg s "$s" '.skills[$s].deps | index("coding-crew-lib") != null' "$REPO_ROOT/registry.json"
    [ "$output" = "true" ] || { echo "$s: no coding-crew-lib dep" >&2; return 1; }
  done
}

@test "install ships discover-mode.sh, host-install.sh, docker-install.sh, manifest-fingerprint.sh and run-checks.sh, all executable" {
  local target f; target=$(fresh_target target-lib)
  run bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  for f in discover-mode.sh host-install.sh docker-install.sh manifest-fingerprint.sh run-checks.sh; do
    [ -x "$target/$LIB/$f" ] || { echo "$f missing or not executable" >&2; return 1; }
  done
}

@test "every platform's dep-install gets coding-crew-lib beside it with a copy of the library, and no .coding-crew/lib is written" {
  local target d; target=$(fresh_target target-all)
  run bash "$REPO_ROOT/install.sh" all --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  [ ! -e "$target/.coding-crew/lib" ]
  for d in .claude/skills .pi/skills .agents/skills .github/skills; do
    [ -f "$target/$d/dep-install/SKILL.md" ] || { echo "missing $d/dep-install/SKILL.md" >&2; return 1; }
    d="$d/coding-crew-lib"
    [ -d "$target/$d/scripts/checks" ] && [ ! -L "$target/$d/scripts/checks" ] || { echo "$d/scripts/checks is not a directory" >&2; return 1; }
    diff -r "$REPO_ROOT/lib/checks" "$target/$d/scripts/checks" || { echo "$d: not a copy of lib/checks" >&2; return 1; }
  done
  # The path the skill text names is a runnable program, not a stub.
  run bash "$target/.pi/skills/coding-crew-lib/scripts/checks/discover-mode.sh" --project-root "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == "Mode discovery: skipped (no compose file: host)" ]]
}

@test "a stale library copy is overwritten on re-install" {
  local target; target=$(fresh_target target-stale)
  mkdir -p "$target/$LIB"
  echo "stale" > "$target/$LIB/discover-mode.sh"
  run bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  ! grep -q '^stale$' "$target/$LIB/discover-mode.sh"
}

@test "uninstall --skill coding-crew-lib removes the library copy, and --skill dep-install the skill" {
  local target; target=$(fresh_target target-uninstall)
  bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target" >/dev/null
  [ -f "$target/$LIB/discover-mode.sh" ]
  run bash "$REPO_ROOT/uninstall.sh" --skills dep-install,coding-crew-lib --project "$target"
  [ "$status" -eq 0 ]
  [ ! -d "$target/$LIB" ]
  [ ! -d "$target/.pi/skills/dep-install" ]
}

@test "install marks the extensionless shim/docker executable" {
  local target; target=$(fresh_target target-shim)
  run bash "$REPO_ROOT/install.sh" claude --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  [ -x "$target/.claude/skills/coding-crew-lib/scripts/checks/shim/docker" ]
}

@test "a re-install keeps the shim executable even when the previous copy was not" {
  local target; target=$(fresh_target target-shim-reinstall)
  bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target" >/dev/null
  chmod -x "$target/$LIB/shim/docker"
  run bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  [ -x "$target/$LIB/shim/docker" ]
}
