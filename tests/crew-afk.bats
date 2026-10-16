#!/usr/bin/env bats

# crew-afk.sh dispatch|status|wait — starts one solve-feature run in a feature's worktree and reports how
# each run ended. A temp clone with a bare `origin` stands in for the user's repo; `claude`, `timeout`,
# `orca` and `herdr` are stubs on PATH that log their argv. The stub claude waits for $T/release, so a
# test can see dispatch return while the run is still going. CREW_AGENT=claude stands in for the
# agent that runs crew-afk; one test leaves it unset and runs crew-afk from a stub agent instead.

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
  export PATH="$STUB:$PATH" CREW_AGENT=claude
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
  run bash "$SCRIPT" dispatch report-cli
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
  [ "$(cat "$T/timeout-argv")" = "1h claude -p /solve-feature report-cli --output-format json --session-id $session --dangerously-skip-permissions" ]
  [ "$(cat "$T/claude-cwd")" = "$WT" ]
  [ "$(cat "$WT/.solve-feature/run.session")" = "$session" ]
  [ "$(cat "$WT/.solve-feature/run.dest")" = local ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "dispatch --branch passes the branch on to solve-feature, and status names it in the re-run" {
  run bash "$SCRIPT" dispatch report-cli --branch feature/SPK-12-report-cli
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  session=$(field session)
  for _ in $(seq 1 50); do [ -f "$T/claude-argv" ] && break; sleep 0.1; done
  [ "$(cat "$T/timeout-argv")" = "1h claude -p /solve-feature report-cli --branch feature/SPK-12-report-cli --output-format json --session-id $session --dangerously-skip-permissions" ]
  wait_run "$WT"
  run bash "$SCRIPT" status report-cli
  [[ "${lines[0]}" == *"re-run /crew-afk report-cli --branch feature/SPK-12-report-cli to continue" ]]
}

@test "a .worktreeinclude directory the repo ignores with a trailing slash leaves the worktree clean" {
  printf '.venv/\n' >> "$MAIN/.gitignore"
  git -C "$MAIN" commit -qam 'ignore .venv/' && git -C "$MAIN" push -q origin main
  mkdir -p "$MAIN/.venv/bin"
  echo .venv >> "$MAIN/.worktreeinclude"
  run bash "$SCRIPT" dispatch report-cli
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -L "$WT/.venv" ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

wait_run() { # <worktree> — release the stub, then wait for the run's pid to exit
  touch "$T/release"
  local pid; pid=$(cat "$1/.solve-feature/run.pid")
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

@test "a second dispatch for the slug reuses its worktree" {
  bash "$SCRIPT" dispatch report-cli >/dev/null
  wait_run "$WT"
  echo kept > "$WT/untracked.txt"
  rm -f "$T/release"
  run bash "$SCRIPT" dispatch report-cli
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  [ -f "$WT/untracked.txt" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 2 ]
}

@test "a dispatch while the slug's run is live exits 1 naming the pid and starts nothing" {
  bash "$SCRIPT" dispatch report-cli >/dev/null
  pid=$(cat "$WT/.solve-feature/run.pid")
  for _ in $(seq 1 50); do [ -f "$T/claude-argv" ] && break; sleep 0.1; done
  rm -f "$T/claude-argv"
  run bash "$SCRIPT" dispatch report-cli
  [ "$status" -eq 1 ]
  [[ "$output" == *"a run for report-cli is still going (pid $pid)"* ]]
  [ "$(cat "$WT/.solve-feature/run.pid")" = "$pid" ]
  sleep 0.3
  [ ! -f "$T/claude-argv" ]
}

@test "an invalid slug, an unknown flag or an unknown --to exits 2, an unknown agent exits 1, and neither creates anything" {
  local args
  for args in "../x" "report-cli --agent claude" "report-cli --to mars" "report-cli --branch a;b" "report-cli --branch x..y"; do
    run bash "$SCRIPT" dispatch $args
    [ "$status" -eq 2 ] || { echo "$args: $output"; return 1; }
    [[ "$output" == *crew-afk:* ]]
  done
  CREW_AGENT=nope run bash "$SCRIPT" dispatch report-cli
  [ "$status" -eq 1 ] && [[ "$output" == *"unknown agent 'nope'"* ]]
  [ ! -e "$T/app-worktrees" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 1 ]
}

@test "dispatch starts the agent CLI that ran it, found among its parent processes" {
  # A bash script shows as `bash …/pi`, as a node-run CLI shows as `node …/copilot`.
  cat > "$T/stub/pi" <<SH
#!/usr/bin/env bash
if [ "\$1" = dispatch ]; then bash "$SCRIPT" "\$@"; else printf '%s\n' "\$*" > "$T/pi-argv"; fi
SH
  chmod +x "$T/stub/pi"
  unset CREW_AGENT
  run pi dispatch report-cli
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$(field session)" ]
  for _ in $(seq 1 50); do [ -f "$T/pi-argv" ] && break; sleep 0.1; done
  [ "$(cat "$T/pi-argv")" = "-p /skill:solve-feature report-cli" ]
}

# ended_run [<stub claude's last line>] [<exit>] — a finished local run on report-cli whose log ends with that line.
ended_run() {
  cat > "$T/stub/claude" <<SH
#!/usr/bin/env bash
echo '${1:-\{"type":"result","subtype":"error_during_execution"\}}'
exit ${2:-1}
SH
  bash "$SCRIPT" dispatch report-cli >/dev/null
  wait_run "$WT"
}

@test "status prints a live run as running, then its outcome line once solve-feature wrote one" {
  bash "$SCRIPT" dispatch report-cli >/dev/null
  pid=$(cat "$WT/.solve-feature/run.pid")
  run bash "$SCRIPT" status
  [ "$output" = "report-cli: running (pid $pid)" ]
  echo 'ready pr=7' > "$WT/.solve-feature/outcome"
  run bash "$SCRIPT" status report-cli
  [ "$output" = "report-cli: ready pr=7" ]
  run bash "$SCRIPT" status other
  [[ "$output" != *report-cli* ]]
}

@test "status on a run that ended without an outcome names the log and the claude session to resume" {
  ended_run
  run bash "$SCRIPT" status
  session=$(cat "$WT/.solve-feature/run.session")
  [ "${lines[0]}" = "report-cli: ended without an outcome — log: $WT/.solve-feature/run.log; re-run /crew-afk report-cli to continue" ]
  [ "${lines[1]}" = "  resume: cd $WT && claude --resume $session" ]
}

@test "wait blocks while the run is going, then prints the status line once the outcome is written" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  bash "$SCRIPT" dispatch report-cli >/dev/null
  bash "$SCRIPT" wait report-cli >"$T/wait-out" &
  waiter=$!
  sleep 0.5
  kill -0 "$waiter"
  echo 'ready pr=7' > "$WT/.solve-feature/outcome"
  wait "$waiter"
  [ "$(cat "$T/wait-out")" = "report-cli: ready pr=7" ]
}

@test "wait on a local run that ends without an outcome prints status's ended line and resume line" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  ended_run
  run bash "$SCRIPT" wait report-cli
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "report-cli: ended without an outcome — log: "* ]]
  [[ "${lines[1]}" == "  resume: cd $WT && claude --resume "* ]]
}

@test "wait on an orca run, which has no run.pid, returns once the outcome is written" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  stub_orca
  bash "$SCRIPT" dispatch report-cli --to orca >/dev/null
  OWT="$T/orca-wt/app-report-cli"
  bash "$SCRIPT" wait report-cli >"$T/wait-out" &
  waiter=$!
  sleep 0.5
  kill -0 "$waiter"
  echo 'ready pr=9' > "$OWT/.solve-feature/outcome"
  wait "$waiter"
  [ "$(cat "$T/wait-out")" = "report-cli: ready pr=9" ]
}

@test "wait follows the slug's latest dispatch, not an older orca run that never wrote an outcome" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  stub_orca
  bash "$SCRIPT" dispatch report-cli --to orca >/dev/null
  touch -t 202001010000 "$T/orca-wt/app-report-cli/.solve-feature/run.slug"
  bash "$SCRIPT" dispatch report-cli >/dev/null
  bash "$SCRIPT" wait report-cli >"$T/wait-out" &
  waiter=$!
  sleep 0.5
  kill -0 "$waiter"
  echo 'ready pr=7' > "$WT/.solve-feature/outcome"
  for _ in $(seq 1 30); do kill -0 "$waiter" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$waiter" 2>/dev/null || { kill "$waiter"; echo "wait did not return"; return 1; }
  [ "$(cat "$T/wait-out")" = "report-cli: ready pr=7" ]
}

@test "wait with no run for the slug exits at once with status's line; a missing slug is a usage error" {
  run bash "$SCRIPT" wait nothing
  [ "$status" -eq 0 ]
  [ "$output" = "no crew-afk run for nothing" ]
  run bash "$SCRIPT" wait
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --help
  [[ "$output" == *"wait <slug>"* ]]
  grep -q '^#   wait <slug>' "$SCRIPT"
}

@test "status leaves out a worktree crew-afk did not dispatch, such as a solve-feature run started by hand" {
  git -C "$MAIN" worktree add -q --detach "$T/by-hand"
  mkdir -p "$T/by-hand/.solve-feature"
  run bash "$SCRIPT" status
  [ "$output" = "no crew-afk run" ]
}

# The orca and herdr stubs log one line per call and answer with the JSON fields the destination reads.
# Their worktree create adds a real detached worktree, which is what the real CLIs leave behind.
stub_orca() {
  export MAIN
  cat > "$T/stub/orca" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$T/orca-calls"
case "$1 $2" in
  "worktree show") exit 1 ;;
  "worktree create") git -C "$MAIN" worktree add -q --detach "$T/orca-wt/app-report-cli" >&2
    echo "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"$T/orca-wt/app-report-cli\"}}}" ;;
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"h1"}}}' ;;
esac
SH
  chmod +x "$T/stub/orca"
}

stub_herdr() {
  cat > "$T/stub/herdr" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$T/herdr-calls"
case "$1 $2" in
  "worktree create") while [ $# -gt 0 ]; do [ "$1" = --path ] && p="$2"; shift; done
    git worktree add -q --detach "$p" >&2 ;;
  "worktree open") echo '{"result":{"workspace":{"workspace_id":"w1"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"p1"}}}' ;;
esac
SH
  chmod +x "$T/stub/herdr"
}

@test "--to orca creates an orca worktree and starts an interactive, uncapped claude in an orca terminal" {
  stub_orca
  run bash "$SCRIPT" dispatch report-cli --to orca
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$T/orca-wt/app-report-cli" ]
  [ -z "$(field pid)" ] && [ -z "$(field session)" ]
  grep -qxF "worktree create --repo path:$MAIN --name report-cli --base-branch main --json" "$T/orca-calls"
  term=$(grep '^terminal create' "$T/orca-calls")
  [[ "$term" == "terminal create --worktree path:$T/orca-wt/app-report-cli --title report-cli --command claude --dangerously-skip-permissions "*"/solve-feature\\ report-cli"* ]]
  [[ "$term" != *budget* ]]
  [ ! -f "$T/timeout-argv" ]
  [ -L "$T/orca-wt/app-report-cli/node_modules" ]
  # orca names the worktree after the repo too; status names the run by its slug and finds it by it.
  run bash "$SCRIPT" status report-cli
  [ "$output" = "report-cli: no outcome yet — orca run, see its terminal" ]
}

@test "--to herdr creates the worktree through herdr and starts an interactive, uncapped claude in a new pane" {
  stub_herdr
  run bash "$SCRIPT" dispatch report-cli --to herdr
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  [ -z "$(field pid)" ] && [ -z "$(field session)" ]
  grep -qxF "worktree create --cwd $MAIN --branch crew-afk/report-cli --base main --path $WT --label report-cli --no-focus" "$T/herdr-calls"
  # Typed into the pane's shell: `agent start` waits for an idle agent, which one given a prompt never is.
  grep -qxF 'pane run p1 claude --dangerously-skip-permissions /solve-feature\ report-cli ' "$T/herdr-calls"
  ! grep -q '^agent start' "$T/herdr-calls"
  [ ! -f "$T/timeout-argv" ]
  run bash "$SCRIPT" status report-cli
  [ "$output" = "report-cli: no outcome yet — herdr run, see its terminal" ]
}

@test "--to orca or herdr without its CLI on PATH exits 1 naming it and creates nothing" {
  local d dirs=()
  while IFS= read -r d; do [ -x "$d/orca" ] || [ -x "$d/herdr" ] || dirs+=("$d"); done < <(tr ':' '\n' <<<"$PATH")
  local to
  for to in orca herdr; do
    run env PATH="$(IFS=:; echo "${dirs[*]}")" bash "$SCRIPT" dispatch report-cli --to "$to"
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$to not found"* ]]
  done
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 1 ]
}

@test "each destination defines only prepare and launch, and sets MODE to headless or interactive" {
  local f
  for f in "$REPO_ROOT"/skills/crew-afk/scripts/destinations/*.sh; do
    [ "$(env -i PATH="$PATH" bash --norc -c 'source "$1"; declare -F' _ "$f" | awk '{print $3}' | sort | paste -sd' ' -)" = "launch prepare" ] || { echo "$f"; return 1; }
    [[ "$(env -i PATH="$PATH" bash --norc -c 'source "$1"; echo "$MODE"' _ "$f")" =~ ^(headless|interactive)$ ]] || { echo "$f"; return 1; }
  done
}

@test "no cost cap on any agent: crew-afk's SKILL.md, script and the guide's local row name no budget" {
  ! grep -niE 'budget|\$10' "$REPO_ROOT/skills/crew-afk/SKILL.md" "$REPO_ROOT/skills/crew-afk/scripts/crew-afk.sh" || false
  ! grep -E '^\| `local`' "$REPO_ROOT/docs/guide.md" | grep -iE 'budget|\$10' || false
}
