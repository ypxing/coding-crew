#!/usr/bin/env bats

# crew-afk.sh dispatch|status — starts one solve-feature run in a feature's worktree and reports how
# each run ended. A temp clone with a bare `origin` stands in for the user's repo; `claude`, `timeout`,
# `orca` and `herdr` are stubs on PATH that log their argv. The stub claude waits for $T/release, so a
# test can see dispatch return while the run is still going.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
  # Physical path: git prints worktree paths resolved (macOS /var → /private/var).
  T=$(cd "$(mktemp -d)" && pwd -P)
  export T
  SCRIPT="$REPO_ROOT/skills/crew-afk/scripts/crew-afk.sh"

  SEED="$T/seed"
  git init -q -b main "$SEED"
  git -C "$SEED" config user.email t@example.com
  git -C "$SEED" config user.name test
  printf '.env\nnode_modules\n' > "$SEED/.gitignore"
  git -C "$SEED" add -A && git -C "$SEED" commit -q -m init
  git clone -q --bare "$SEED" "$T/origin.git"
  MAIN="$T/app"
  git clone -q "$T/origin.git" "$MAIN"
  echo 'SECRET=1' > "$MAIN/.env"
  mkdir -p "$MAIN/node_modules/pkg"
  printf '# deps\nnode_modules\n' > "$MAIN/.worktreeinclude"
  WT="$T/app-worktrees/report-cli"

  STUB="$T/stub"
  mkdir -p "$STUB"
  cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$T/claude-argv"
pwd > "$T/claude-cwd"
for _ in $(seq 1 100); do [ -f "$T/release" ] && break; sleep 0.1; done
echo '{"type":"result","subtype":"success","total_cost_usd":1.5,"session_id":"x"}'
SH
  cat > "$STUB/timeout" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$T/timeout-argv"
shift
exec "$@"
SH
  chmod +x "$STUB"/*
  export PATH="$STUB:$PATH"
  cd "$MAIN"
}

teardown() {
  touch "$T/release"
  local pid
  for pid in $(cat "$T"/*/*/.solve-feature/run.pid 2>/dev/null); do
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  done
  rm -rf "$T"
}

field() { sed -n "s/^$1=//p" <<<"$output"; }

@test "dispatch --to local starts a capped headless claude in a fresh detached worktree and returns at once" {
  run bash "$SCRIPT" dispatch report-cli --agent claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  [ "$(field log)" = "$WT/.solve-feature/run.log" ]
  pid=$(field pid)
  session=$(field session)
  [[ "$session" =~ ^[0-9a-f-]{36}$ ]]
  kill -0 "$pid"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse origin/main)" ]
  ! git -C "$WT" symbolic-ref -q HEAD
  [ -L "$WT/node_modules" ] && [ "$(readlink "$WT/node_modules")" = "$MAIN/node_modules" ]
  [ -f "$WT/.env" ] && [ ! -L "$WT/.env" ]
  for _ in $(seq 1 50); do [ -f "$T/claude-argv" ] && break; sleep 0.1; done
  [ "$(cat "$T/timeout-argv")" = "1h claude -p /solve-feature report-cli --output-format json --session-id $session --max-budget-usd 10 --dangerously-skip-permissions" ]
  [ "$(cat "$T/claude-cwd")" = "$WT" ]
  [ "$(cat "$WT/.solve-feature/run.session")" = "$session" ]
  [ "$(cat "$WT/.solve-feature/run.dest")" = local ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

wait_run() { # <worktree> — release the stub, then wait for the run's pid to exit
  touch "$T/release"
  local pid; pid=$(cat "$1/.solve-feature/run.pid")
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

@test "a second dispatch for the slug reuses its worktree" {
  bash "$SCRIPT" dispatch report-cli --agent claude >/dev/null
  wait_run "$WT"
  echo kept > "$WT/untracked.txt"
  rm -f "$T/release"
  run bash "$SCRIPT" dispatch report-cli --agent claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  [ -f "$WT/untracked.txt" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 2 ]
}

@test "a dispatch while the slug's run is live exits 1 naming the pid and starts nothing" {
  bash "$SCRIPT" dispatch report-cli --agent claude >/dev/null
  pid=$(cat "$WT/.solve-feature/run.pid")
  for _ in $(seq 1 50); do [ -f "$T/claude-argv" ] && break; sleep 0.1; done
  rm -f "$T/claude-argv"
  run bash "$SCRIPT" dispatch report-cli --agent claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"a run for report-cli is still going (pid $pid)"* ]]
  [ "$(cat "$WT/.solve-feature/run.pid")" = "$pid" ]
  sleep 0.3
  [ ! -f "$T/claude-argv" ]
}

@test "an invalid slug, an unknown --agent or an unknown --to exits 2 and creates nothing" {
  local args
  for args in "../x --agent claude" "report-cli --agent nope" "report-cli --agent claude --to mars" "report-cli"; do
    run bash "$SCRIPT" dispatch $args
    [ "$status" -eq 2 ] || { echo "$args: $output"; return 1; }
    [[ "$output" == *crew-afk:* ]]
  done
  [ ! -e "$T/app-worktrees" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 1 ]
}
