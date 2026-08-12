#!/usr/bin/env bats

# codex platform support: install paths, agent TOML shims, skill variants, dispatch script

load helpers/render

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "codex is an accepted platform and skills land in .agents/skills" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill tdd
  [ "$status" -eq 0 ]
  # Codex scans .agents/skills, never .codex/skills
  [ -f "$TEMP_DIR/.agents/skills/tdd/SKILL.md" ]
  [ ! -d "$TEMP_DIR/.codex/skills" ]
}

@test "codex crew-afk installs both agent-deps as .codex/agents TOML files" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk

  [ -f "$TEMP_DIR/.codex/agents/crew-coder.toml" ]
  [ -f "$TEMP_DIR/.codex/agents/crew-code-reviewer.toml" ]
  [ -f "$TEMP_DIR/.agents/skills/crew-afk/SKILL.md" ]

  # protocol placeholder must be expanded
  ! grep -q '{{PROTOCOL}}' "$TEMP_DIR/.codex/agents/crew-code-reviewer.toml"
}

@test "installed codex agent files are valid TOML with the required custom-agent fields" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk

  for agent in crew-coder crew-code-reviewer; do
    # Content goes in on stdin, not as a path: on Windows the runner's python3 is a
    # native build that cannot resolve MSYS paths like /tmp/tmp.XXXX/...
    run bash -c "python3 -c \"
import tomllib, sys
d = tomllib.loads(sys.stdin.buffer.read().decode('utf-8'))
for key in ('name', 'description', 'developer_instructions'):
    assert d.get(key), 'missing ' + key
assert len(d['developer_instructions']) > 200
\" < '$TEMP_DIR/.codex/agents/$agent.toml'"
    [ "$status" -eq 0 ]
  done
}

@test "codex crew-afk SKILL.md is the codex variant with no leftover variants" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk

  grep -q "AFK Issue Sprint — Codex" "$TEMP_DIR/.agents/skills/crew-afk/SKILL.md"
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/codex.SKILL.md" ]
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/pi.SKILL.md" ]
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/copilot.SKILL.md" ]
}

@test "platform=all installs codex alongside claude, copilot, and pi" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh all --skill crew-afk

  [ -f "$TEMP_DIR/.claude/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.github/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.pi/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.agents/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.codex/agents/crew-coder.toml" ]
}

@test "codex crew-afk ships the codex dispatch script, executable and syntactically valid" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk

  [ -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" ]
  run bash -n "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh"
  [ "$status" -eq 0 ]
}

@test "dispatch-codex-agent.sh requires its arguments" {
  cd "$SCRIPT_DIR"
  run bash skills/crew-afk/scripts/dispatch-codex-agent.sh --agent crew-coder
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dir is required"* ]]
}

@test "dispatch-codex-agent.sh reports a missing agent definition" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/wt"
  echo "task" > "$TEMP_DIR/prompt.md"
  run env HOME="$TEMP_DIR" MAIN_ROOT="$TEMP_DIR" \
    bash skills/crew-afk/scripts/dispatch-codex-agent.sh \
      --agent does-not-exist --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent definition not found"* ]]
}

@test "dispatch-codex-agent.sh wires the agent TOML onto codex exec" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk >/dev/null

  mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/wt"
  printf '#!/usr/bin/env bash\necho "ARGS: $*"\ncat >/dev/null\n' > "$TEMP_DIR/bin/codex"
  chmod +x "$TEMP_DIR/bin/codex"
  echo "implement issue 01" > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" \
      --agent crew-coder --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md" \
      --out "$TEMP_DIR/report.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exec"* ]]
  [[ "$output" == *"--cd $TEMP_DIR/wt"* ]]
  [[ "$output" == *"--output-last-message $TEMP_DIR/report.md"* ]]
  # coder must be able to write in its worktree
  [[ "$output" == *"--sandbox workspace-write"* ]]
}

@test "dispatch-codex-agent.sh makes the worktree's git dir writable in the sandbox" {
  # A linked worktree's index lives in the main repo's .git dir, which codex's
  # workspace-write sandbox keeps read-only even when its parent is passed with --add-dir.
  # Without an explicit writable root, `git add` in a worker fails with
  # "index.lock: Operation not permitted" — a codex sprint where nothing can ever commit.
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk >/dev/null

  git -C "$TEMP_DIR" init -q -b main
  git -C "$TEMP_DIR" config user.email t@test
  git -C "$TEMP_DIR" config user.name T
  echo x > "$TEMP_DIR/README.md"
  git -C "$TEMP_DIR" add -A
  git -C "$TEMP_DIR" commit -qm init
  git -C "$TEMP_DIR" worktree add -q "$TEMP_DIR/wt" -b work

  mkdir -p "$TEMP_DIR/bin"
  printf '#!/usr/bin/env bash\necho "ARGS: $*"\ncat >/dev/null\n' > "$TEMP_DIR/bin/codex"
  chmod +x "$TEMP_DIR/bin/codex"
  echo "implement issue 01" > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" \
      --agent crew-coder --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -eq 0 ]
  common_dir=$(cd "$TEMP_DIR/wt" && git rev-parse --git-common-dir)
  [[ "$output" == *"sandbox_workspace_write.writable_roots=[\"$common_dir\"]"* ]] || {
    echo "$output" >&2; return 1; }
}

@test "dispatch-codex-agent.sh adds no writable root for a read-only reviewer" {
  # The reviewer never commits, so widening its sandbox would buy nothing.
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk >/dev/null

  mkdir -p "$TEMP_DIR/bin"
  printf '#!/usr/bin/env bash\necho "ARGS: $*"\ncat >/dev/null\n' > "$TEMP_DIR/bin/codex"
  chmod +x "$TEMP_DIR/bin/codex"
  echo "review branch" > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" \
      --agent crew-code-reviewer --dir "$TEMP_DIR" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"writable_roots"* ]]
}

@test "dispatch-codex-agent.sh honours the reviewer's read-only sandbox" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk >/dev/null

  mkdir -p "$TEMP_DIR/bin"
  printf '#!/usr/bin/env bash\necho "ARGS: $*"\ncat >/dev/null\n' > "$TEMP_DIR/bin/codex"
  chmod +x "$TEMP_DIR/bin/codex"
  echo "review branch" > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" \
      --agent crew-code-reviewer --dir "$TEMP_DIR" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--sandbox read-only"* ]]
}

@test "--model overrides the agent TOML, --model inherit passes none" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk >/dev/null

  mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/wt"
  printf '#!/usr/bin/env bash\necho "ARGS: $*"\ncat >/dev/null\n' > "$TEMP_DIR/bin/codex"
  chmod +x "$TEMP_DIR/bin/codex"
  echo "task" > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" \
      --agent crew-coder --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md" --model gpt-5.6
  [[ "$output" == *"--model gpt-5.6"* ]]

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" \
      --agent crew-coder --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md" --model inherit
  [[ "$output" != *"--model"* ]]
}

@test "uninstall removes codex-installed skills and agents" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk
  [ -d "$TEMP_DIR/.agents/skills/crew-afk" ]

  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill crew-afk
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --agent crew-coder

  [ ! -d "$TEMP_DIR/.agents/skills/crew-afk" ]
  [ ! -f "$TEMP_DIR/.codex/agents/crew-coder.toml" ]
}

@test "squash-commits.sh accepts --platform codex" {
  cd "$SCRIPT_DIR"
  run grep -n 'PLATFORM" = "codex"' skills/crew-afk/scripts/squash-commits.sh
  [ "$status" -eq 0 ]
}

@test "codex crew-afk skill does not reference pi paths or the pi dispatch script" {
  cd "$SCRIPT_DIR"
  run grep -n '\.pi/\|dispatch-agent\.sh\|pi -p' "$(afk_variant codex)"
  [ "$status" -ne 0 ]
}

@test "codex install excludes pi's dispatch-agent.sh" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk

  [ -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" ]
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-agent.sh" ]
}

@test "reinstall prunes a foreign dispatch script left by an older install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk
  # Simulate the pre-gating install that copied every platform's scripts
  touch "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-agent.sh"

  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-agent.sh" ]
}
