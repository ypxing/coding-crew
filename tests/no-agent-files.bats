#!/usr/bin/env bats

# crew-afk dispatches every role from its rendered protocol, so no platform gets an agent file:
# the protocols live in orchestrator/roles/ and ship with the orchestrator to
# .coding-crew/crew-afk/roles/, and an update removes the files an older install wrote
# (tests/retired-agents.bats covers that migration).

load helpers/render
load helpers/platforms

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  T="$(mktemp -d)"
}
teardown() { rm -rf "$T"; }

# Where a platform could keep agent files: beside its project and user skills dirs, and in its
# config dir.
AGENT_DIRS=()
for _p in "${PLATFORMS[@]}"; do
  AGENT_DIRS+=("$(dirname "$(platform_field "$_p" projectSkills)")/agents"
               "$(dirname "$(platform_field "$_p" userSkills)")/agents"
               "$(platform_field "$_p" configDir)/agents")
done
unset _p

@test "there is no agents/ source tree: each role's protocol is orchestrator/roles/<role>.md" {
  [ ! -e "$REPO_ROOT/agents" ]
  for r in coder reviewer triage; do
    [ -f "$REPO_ROOT/orchestrator/roles/$r.md" ]
  done
}

@test "a fresh install writes no agent file and ships each protocol with the orchestrator" {
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./install.sh all --skill crew-afk >/dev/null)
  for d in "${AGENT_DIRS[@]}"; do
    [ ! -e "$T/$d" ] || { echo "found $d"; return 1; }
  done
  for r in coder reviewer triage; do
    [ -f "$T/.coding-crew/crew-afk/roles/$r.md" ]
  done
  [ -f "$T/.coding-crew/skills/_shared/fragments/findings-rubric.md" ]
}

@test "installing crew-afk removes the common/ and per-platform fragment directories an older install wrote" {
  for d in common "${PLATFORMS[@]}"; do
    mkdir -p "$T/.coding-crew/skills/_shared/fragments/$d"
    echo stale > "$T/.coding-crew/skills/_shared/fragments/$d/tracker-configuration.md"
  done
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./install.sh claude --skill crew-afk >/dev/null)
  run find "$T/.coding-crew/skills/_shared/fragments" -mindepth 1 -type d
  [ -z "$output" ]
  [ -f "$T/.coding-crew/skills/_shared/fragments/findings-rubric.md" ]
}

@test "uninstall --skill crew-afk removes the protocols and the shared fragments" {
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./install.sh claude --skill crew-afk >/dev/null)
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./uninstall.sh --skill crew-afk >/dev/null)
  [ ! -e "$T/.coding-crew/crew-afk" ]
  [ ! -e "$T/.coding-crew/skills/_shared/fragments" ]
}

@test "the rendered crew-afk launchers name no agent file" {
  for p in "${PLATFORMS[@]}"; do
    run cat "$(afk_variant "$p")"
    if echo "$output" | grep -qF -e --agent -e 'agent definition' $(printf -- '-e %s ' "${AGENT_DIRS[@]}"); then
      echo "$p launcher names an agent file"; return 1
    fi
  done
}
