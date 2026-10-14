#!/usr/bin/env bats

# dep-install's scripts are the checks library (lib/checks): installed once to
# <root>/.coding-crew/lib/checks and linked as <skill-dir>/scripts/checks into each skill whose
# registry `libs` names it, so the skill text's "<skill-dir>/scripts/checks/<script>" runs the one copy.

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

LIB=".coding-crew/lib/checks"

@test "registry links the checks library into dep-install, solve-issue, solve-feature and address-pr-comments" {
  local s
  for s in dep-install solve-issue solve-feature address-pr-comments; do
    run jq -r --arg s "$s" '.skills[$s].libs | index("checks") != null' "$REPO_ROOT/registry.json"
    [ "$output" = "true" ] || { echo "$s: no checks lib" >&2; return 1; }
  done
}

@test "install ships detect-mode.sh, host-install.sh, docker-install.sh, manifest-fingerprint.sh and run-checks.sh, all executable" {
  local target f; target=$(fresh_target target-lib)
  run bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  for f in detect-mode.sh host-install.sh docker-install.sh manifest-fingerprint.sh run-checks.sh; do
    [ -x "$target/$LIB/$f" ] || { echo "$f missing or not executable" >&2; return 1; }
  done
}

@test "the library installs once, not once per platform, and every platform's dep-install links it" {
  local target d; target=$(fresh_target target-all)
  run bash "$REPO_ROOT/install.sh" all --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  run bash -c "find '$target' -name 'detect-mode.sh' | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "1" ]
  for d in .claude/skills/dep-install .pi/skills/dep-install .agents/skills/dep-install .github/skills/dep-install; do
    [ -f "$target/$d/SKILL.md" ] || { echo "missing $d/SKILL.md" >&2; return 1; }
    [ -L "$target/$d/scripts/checks" ] || { echo "$d/scripts/checks is not a link" >&2; return 1; }
    [ -f "$target/$d/scripts/checks/host-install.sh" ] || { echo "$d: the link does not resolve" >&2; return 1; }
  done
  # The path the skill text names is a runnable program, not a stub.
  run bash "$target/.pi/skills/dep-install/scripts/checks/detect-mode.sh" --project-root "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == "USE_HOST" || "$output" == "USE_DOCKER" ]]
}

@test "a stale library copy is overwritten on re-install" {
  local target; target=$(fresh_target target-stale)
  mkdir -p "$target/$LIB"
  echo "stale" > "$target/$LIB/detect-mode.sh"
  run bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  ! grep -q '^stale$' "$target/$LIB/detect-mode.sh"
}

@test "uninstall --skill dep-install removes the library no remaining skill uses" {
  local target; target=$(fresh_target target-uninstall)
  bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target" >/dev/null
  [ -f "$target/$LIB/detect-mode.sh" ]
  run bash "$REPO_ROOT/uninstall.sh" --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  [ ! -d "$target/$LIB" ]
  [ ! -d "$target/.pi/skills/dep-install" ]
}

@test "install marks the extensionless shim/docker and shim/docker-compose executable" {
  local target; target=$(fresh_target target-shim)
  run bash "$REPO_ROOT/install.sh" claude --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  [ -x "$target/$LIB/shim/docker" ]
  [ -x "$target/$LIB/shim/docker-compose" ]
  [ -x "$target/.claude/skills/dep-install/scripts/checks/shim/docker" ]
}

@test "a re-install keeps the shim executable even when the previous copy was not" {
  local target; target=$(fresh_target target-shim-reinstall)
  bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target" >/dev/null
  chmod -x "$target/$LIB/shim/docker"
  run bash "$REPO_ROOT/install.sh" pi --skill dep-install --project "$target"
  [ "$status" -eq 0 ]
  [ -x "$target/$LIB/shim/docker" ]
}
