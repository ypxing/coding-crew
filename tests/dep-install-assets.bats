#!/usr/bin/env bats

# dep-install's scripts are two things at once: skill text the model reads and launches
# ("run scripts/detect-mode.sh from the same directory you read this skill file from"),
# and a mechanism the platform-neutral orchestrator has to run without knowing which
# platform a repo installed. The per-platform copies stay for the first reader; a single
# copy at .coding-crew/dep-install/scripts exists for the second.
#
# Both must hold at once, which is what this file pins.

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

@test "registry declares dep-install's scripts at a platform-neutral path" {
  run jq -r '.skills["dep-install"].assets.source' "$REPO_ROOT/registry.json"
  [ "$output" = "skills/dep-install/scripts" ]
  run jq -r '.skills["dep-install"].assets.dest' "$REPO_ROOT/registry.json"
  [ "$output" = ".coding-crew/dep-install/scripts" ]
}

@test "install ships detect-mode.sh, host-install.sh and docker-install.sh, all executable" {
  local target; target=$(fresh_target target-neutral)
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" pi --skill dep-install
  [ "$status" -eq 0 ]

  [ -f "$target/.coding-crew/dep-install/scripts/detect-mode.sh" ]
  [ -f "$target/.coding-crew/dep-install/scripts/host-install.sh" ]
  [ -f "$target/.coding-crew/dep-install/scripts/docker-install.sh" ]
  [ -x "$target/.coding-crew/dep-install/scripts/detect-mode.sh" ]
  [ -x "$target/.coding-crew/dep-install/scripts/host-install.sh" ]
  [ -x "$target/.coding-crew/dep-install/scripts/docker-install.sh" ]
}

@test "the neutral tree installs once, not once per platform" {
  local target; target=$(fresh_target target-all)
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" all --skill dep-install
  [ "$status" -eq 0 ]
  run bash -c "find '$target/.coding-crew' -name 'detect-mode.sh' | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "1" ]
}

@test "a stale neutral copy is overwritten on re-install" {
  local target; target=$(fresh_target target-stale)
  mkdir -p "$target/.coding-crew/dep-install/scripts"
  echo "stale" > "$target/.coding-crew/dep-install/scripts/detect-mode.sh"
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" pi --skill dep-install
  [ "$status" -eq 0 ]
  ! grep -q '^stale$' "$target/.coding-crew/dep-install/scripts/detect-mode.sh"
}

@test "uninstall --skill dep-install removes the neutral tree" {
  local target; target=$(fresh_target target-uninstall)
  TARGET_REPO="$target" bash "$REPO_ROOT/install.sh" pi --skill dep-install >/dev/null
  [ -f "$target/.coding-crew/dep-install/scripts/detect-mode.sh" ]
  TARGET_REPO="$target" run bash "$REPO_ROOT/uninstall.sh" --skill dep-install
  [ "$status" -eq 0 ]
  [ ! -d "$target/.coding-crew/dep-install" ]
}

@test "the per-platform skill copies still install and still run" {
  local target; target=$(fresh_target target-per-platform)
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" all --skill dep-install
  [ "$status" -eq 0 ]

  local d
  for d in .claude/skills/dep-install .pi/skills/dep-install \
           .agents/skills/dep-install .github/skills/dep-install; do
    [ -f "$target/$d/SKILL.md" ] || { echo "missing $d/SKILL.md" >&2; return 1; }
    [ -f "$target/$d/scripts/detect-mode.sh" ] || {
      echo "missing $d/scripts/detect-mode.sh" >&2; return 1; }
    [ -f "$target/$d/scripts/host-install.sh" ] || {
      echo "missing $d/scripts/host-install.sh" >&2; return 1; }
  done

  # "run scripts/detect-mode.sh from the same directory you read this skill file from"
  # still works: the copy next to SKILL.md is a runnable program, not a stub.
  run bash "$target/.pi/skills/dep-install/scripts/detect-mode.sh" --project-root "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == "USE_HOST" || "$output" == "USE_DOCKER" ]]
}
