#!/usr/bin/env bats

# crew-afk.sh dispatch|status|wait — starts one solve-feature run in a feature's worktree and reports how
# each run ended. A temp clone with a bare `origin` stands in for the user's repo; `claude`, `timeout`,
# `orca` and `herdr` are stubs on PATH that log their argv. The stub claude waits for $T/release, so a
# test can see dispatch return while the run is still going. $LAUNCH stands in for the launch command the host
# agent passes after `--`; it holds an argument with spaces, which must reach the stub as one.

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
echo '{"type":"result","subtype":"success","total_cost_usd":1.734,"duration_ms":1380000,"session_id":"x"}'
SH
  cat > "$STUB/timeout" <<'SH'
#!/usr/bin/env bash
echo "$*" > "$T/timeout-argv"
shift
exec "$@"
SH
  chmod +x "$STUB"/*
  export PATH="$STUB:$PATH"
  LAUNCH=(-- claude -p "Use the solve-feature skill on report-cli" --output-format json)
  cd "$MAIN"
}

teardown() {
  touch "$T/release"
  local pid
  for pid in $(cat "$T"/*/*/.coding-crew/solve-feature/run.pid 2>/dev/null); do
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  done
  rm -rf "$T"
}

field() { sed -n "s/^$1=//p" <<<"$output"; }

@test "dispatch --to local runs the launch argv verbatim under the 1h cap in a fresh detached worktree and returns at once" {
  run bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  [ "$(field log)" = "$WT/.coding-crew/solve-feature/run.log" ]
  pid=$(field pid)
  ! grep -q '^session=' <<<"$output"
  kill -0 "$pid"
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$MAIN" rev-parse origin/main)" ]
  ! git -C "$WT" symbolic-ref -q HEAD
  [ -L "$WT/node_modules" ] && [ "$(readlink "$WT/node_modules")" = "$MAIN/node_modules" ]
  [ -f "$WT/.env" ] && [ ! -L "$WT/.env" ]
  for _ in $(seq 1 50); do [ -f "$T/claude-argv" ] && break; sleep 0.1; done
  [ "$(cat "$T/timeout-argv")" = "1h claude -p Use the solve-feature skill on report-cli --output-format json" ]
  [ "$(cat "$T/claude-argv")" = $'-p\nUse the solve-feature skill on report-cli\n--output-format\njson' ]
  [ "$(cat "$T/claude-cwd")" = "$WT" ]
  [ ! -e "$WT/.coding-crew/solve-feature/run.session" ]
  [ "$(cat "$WT/.coding-crew/solve-feature/run.dest")" = local ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "dispatch --branch leaves the launch argv as given, and status names the branch in the re-run" {
  run bash "$SCRIPT" dispatch report-cli --branch feature/SPK-12-report-cli -- claude -p "Use the solve-feature skill on report-cli --branch feature/SPK-12-report-cli"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for _ in $(seq 1 50); do [ -f "$T/claude-argv" ] && break; sleep 0.1; done
  [ "$(cat "$T/timeout-argv")" = "1h claude -p Use the solve-feature skill on report-cli --branch feature/SPK-12-report-cli" ]
  wait_run "$WT"
  run bash "$SCRIPT" status report-cli
  [[ "${lines[0]}" == *"re-run /crew-afk report-cli --branch feature/SPK-12-report-cli to continue" ]]
}

@test "a .worktreeinclude directory the repo ignores with a trailing slash leaves the worktree clean" {
  printf '.venv/\n' >> "$MAIN/.gitignore"
  git -C "$MAIN" commit -qam 'ignore .venv/' && git -C "$MAIN" push -q origin main
  mkdir -p "$MAIN/.venv/bin"
  echo .venv >> "$MAIN/.worktreeinclude"
  run bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -L "$WT/.venv" ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

wait_run() { # <worktree> — release the stub, then wait for the run's pid to exit
  touch "$T/release"
  local pid; pid=$(cat "$1/.coding-crew/solve-feature/run.pid")
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

@test "a second dispatch for the slug reuses its worktree" {
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  wait_run "$WT"
  echo kept > "$WT/untracked.txt"
  rm -f "$T/release"
  run bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  [ -f "$WT/untracked.txt" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 2 ]
}

@test "a dispatch while the slug's run is live exits 1 naming the pid and starts nothing" {
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  pid=$(cat "$WT/.coding-crew/solve-feature/run.pid")
  for _ in $(seq 1 50); do [ -f "$T/claude-argv" ] && break; sleep 0.1; done
  rm -f "$T/claude-argv"
  run bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a run for report-cli is still going (pid $pid)"* ]]
  [ "$(cat "$WT/.coding-crew/solve-feature/run.pid")" = "$pid" ]
  sleep 0.3
  [ ! -f "$T/claude-argv" ]
}

@test "an invalid slug, an unknown flag or an unknown --to exits 2, and creates nothing" {
  local args
  for args in "../x" "report-cli --not-a-flag x" "report-cli --to mars" "report-cli --branch a;b" "report-cli --branch x..y"; do
    run bash "$SCRIPT" dispatch $args -- claude
    [ "$status" -eq 2 ] || { echo "$args: $output"; return 1; }
    [[ "$output" == *crew-afk:* ]]
  done
  [ ! -e "$T/app-worktrees" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 1 ]
}

@test "dispatch with no launch command after -- exits 2 saying it is missing, and creates nothing" {
  local args
  for args in "report-cli" "report-cli --" "report-cli --to orca --"; do
    run bash "$SCRIPT" dispatch $args
    [ "$status" -eq 2 ] || { echo "$args: $output"; return 1; }
    [[ "$output" == *"crew-afk: the launch command is missing"* ]] || { echo "$args: $output"; return 1; }
  done
  [ ! -e "$T/app-worktrees" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 1 ]
}

@test "crew-afk.sh and its destinations name no agent CLI, read no process table, and set no CREW_AGENT or MODE" {
  local f
  for f in "$SCRIPT" "$REPO_ROOT"/skills/crew-afk/scripts/destinations/*.sh; do
    ! grep -nwiE 'claude|copilot|codex|pi|ps|CREW_AGENT' "$f" || { echo "$f"; return 1; }
    ! grep -n 'MODE=' "$f" || { echo "$f"; return 1; }
  done
}

# ended_run [<stub claude's last line>] [<exit>] — a finished local run on report-cli whose log ends with that line.
ended_run() {
  cat > "$T/stub/claude" <<SH
#!/usr/bin/env bash
echo '${1:-\{"type":"result","subtype":"error_during_execution"\}}'
exit ${2:-1}
SH
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  wait_run "$WT"
}

@test "status prints a live run as running, then its outcome line once solve-feature wrote one" {
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  pid=$(cat "$WT/.coding-crew/solve-feature/run.pid")
  run bash "$SCRIPT" status
  [ "$output" = "report-cli: running (pid $pid)" ]
  echo 'ready pr=7' > "$WT/.coding-crew/solve-feature/outcome"
  run bash "$SCRIPT" status report-cli
  [ "$output" = "report-cli: ready pr=7" ]
  run bash "$SCRIPT" status other
  [[ "$output" != *report-cli* ]]
}

@test "status on a run that ended without an outcome names the log and the re-run, and no resume line" {
  ended_run
  run bash "$SCRIPT" status
  [ "$output" = "report-cli: ended without an outcome — log: $WT/.coding-crew/solve-feature/run.log; re-run /crew-afk report-cli to continue" ]
}

@test "wait blocks while the run is going, then prints the status line once the outcome is written" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  bash "$SCRIPT" wait report-cli >"$T/wait-out" &
  waiter=$!
  sleep 0.5
  kill -0 "$waiter"
  echo 'ready pr=7' > "$WT/.coding-crew/solve-feature/outcome"
  touch "$T/release"
  wait "$waiter"
  [ "$(cat "$T/wait-out")" = 'report-cli: ready pr=7 cost=$1.73 (23 min)' ]
}

@test "wait on a local run keeps blocking after the outcome until the run's process is gone, then prints its cost" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  echo 'ready pr=7' > "$WT/.coding-crew/solve-feature/outcome"
  bash "$SCRIPT" wait report-cli >"$T/wait-out" &
  waiter=$!
  sleep 0.5
  kill -0 "$waiter"
  [ ! -s "$T/wait-out" ]
  touch "$T/release"
  wait "$waiter"
  [ "$(cat "$T/wait-out")" = 'report-cli: ready pr=7 cost=$1.73 (23 min)' ]
}

@test "status adds the cost and minutes from the claude result that ends run.log, and only when there is one" {
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  wait_run "$WT"
  echo 'ready pr=7' > "$WT/.coding-crew/solve-feature/outcome"
  printf 'x\n{"type":"result","total_cost_usd":1.734,"duration_ms":1380000}\n' > "$WT/.coding-crew/solve-feature/run.log"
  run bash "$SCRIPT" status report-cli
  [ "$output" = 'report-cli: ready pr=7 cost=$1.73 (23 min)' ]
  printf 'claude: error\n' > "$WT/.coding-crew/solve-feature/run.log"
  run bash "$SCRIPT" status report-cli
  [ "$output" = 'report-cli: ready pr=7' ]
  rm "$WT/.coding-crew/solve-feature/run.log"
  run bash "$SCRIPT" status report-cli
  [ "$output" = 'report-cli: ready pr=7' ]
}

@test "wait on a local run that ends without an outcome prints status's ended line alone" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  ended_run
  run bash "$SCRIPT" wait report-cli
  [ "$status" -eq 0 ]
  [[ "$output" == "report-cli: ended without an outcome — log: "* ]]
  [ "${#lines[@]}" -eq 1 ]
}

@test "wait on an orca run, which has no run.pid, returns once the outcome is written" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  stub_orca
  bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}" >/dev/null
  OWT="$T/orca-wt/app-report-cli"
  bash "$SCRIPT" wait report-cli >"$T/wait-out" &
  waiter=$!
  sleep 0.5
  kill -0 "$waiter"
  echo 'ready pr=9' > "$OWT/.coding-crew/solve-feature/outcome"
  wait "$waiter"
  [ "$(cat "$T/wait-out")" = "report-cli: ready pr=9" ]
}

@test "wait follows the slug's latest dispatch, not an older orca run that never wrote an outcome" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  stub_orca
  bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}" >/dev/null
  touch -t 202001010000 "$T/orca-wt/app-report-cli/.coding-crew/solve-feature/run.slug"
  echo '{"ok":true,"result":{"terminal":{"handle":"h1","connected":false,"orphaned":true}}}' > "$T/orca-show"
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  bash "$SCRIPT" wait report-cli >"$T/wait-out" &
  waiter=$!
  sleep 0.5
  kill -0 "$waiter"
  echo 'ready pr=7' > "$WT/.coding-crew/solve-feature/outcome"
  touch "$T/release"
  for _ in $(seq 1 30); do kill -0 "$waiter" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$waiter" 2>/dev/null || { kill "$waiter"; echo "wait did not return"; return 1; }
  [ "$(cat "$T/wait-out")" = 'report-cli: ready pr=7 cost=$1.73 (23 min)' ]
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
  mkdir -p "$T/by-hand/.coding-crew/solve-feature"
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
  "worktree show") [ -d "$T/orca-wt/app-report-cli" ] || exit 1
    echo "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"$T/orca-wt/app-report-cli\"}}}" ;;
  "worktree create") git -C "$MAIN" worktree add -q --detach "$T/orca-wt/app-report-cli" >&2
    echo "{\"ok\":true,\"result\":{\"worktree\":{\"path\":\"$T/orca-wt/app-report-cli\"}}}" ;;
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"h1"}}}' ;;
  # $T/orca-show holds what terminal show prints (default: connected); $T/orca-show-fail makes it fail.
  "terminal show") [ ! -f "$T/orca-show-fail" ] || { echo "orca: server unreachable" >&2; exit 1; }
    cat "$T/orca-show" 2>/dev/null || echo '{"ok":true,"result":{"terminal":{"handle":"h1","connected":true,"orphaned":false}}}' ;;
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
  # $T/herdr-root-agent names the agent in the workspace's root pane (default: none, the startup shell).
  "worktree open") echo "{\"result\":{\"workspace\":{\"workspace_id\":\"w1\"},\"root_pane\":{\"pane_id\":\"w1:p1\",\"agent\":\"$(cat "$T/herdr-root-agent" 2>/dev/null)\"}}}" ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"t1"},"root_pane":{"pane_id":"w1:p2"}}}' ;;
  # $T/herdr-run-fail: typing the command into the pane fails.
  "pane run") [ ! -f "$T/herdr-run-fail" ] || exit 1 ;;
  # $T/herdr-pane-gone: the pane is gone; $T/herdr-pane-fail: herdr cannot tell.
  "pane get") [ ! -f "$T/herdr-pane-gone" ] || { echo '{"error":{"code":"pane_not_found","message":"no pane"}}' >&2; exit 1; }
    [ ! -f "$T/herdr-pane-fail" ] || { echo '{"error":{"code":"server_down","message":"no server"}}' >&2; exit 1; }
    echo "{\"result\":{\"pane\":{\"pane_id\":\"$3\"}}}" ;;
esac
SH
  chmod +x "$T/stub/herdr"
}

@test "--to orca creates an orca worktree and types the launch argv, quoted and uncapped, into an orca terminal" {
  stub_orca
  run bash "$SCRIPT" dispatch report-cli --to orca -- claude --dangerously-skip-permissions "/solve-feature report-cli"
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

@test "--to herdr creates the worktree through herdr and types the launch argv, quoted and uncapped, into its idle startup pane" {
  stub_herdr
  run bash "$SCRIPT" dispatch report-cli --to herdr -- claude --dangerously-skip-permissions "/solve-feature report-cli"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  [ -z "$(field pid)" ] && [ -z "$(field session)" ]
  grep -qxF "worktree create --cwd $MAIN --branch crew-afk/report-cli --base main --path $WT --label report-cli --no-focus" "$T/herdr-calls"
  # Typed into the pane's shell: `agent start` waits for an idle agent, which one given a prompt never is.
  grep -qxF 'pane run w1:p1 claude --dangerously-skip-permissions /solve-feature\ report-cli ' "$T/herdr-calls"
  ! grep -q '^tab create' "$T/herdr-calls"
  ! grep -q '^agent start' "$T/herdr-calls"
  [ "$(cat "$WT/.coding-crew/solve-feature/run.pane")" = w1:p1 ]
  [ ! -f "$T/timeout-argv" ]
  run bash "$SCRIPT" status report-cli
  [ "$output" = "report-cli: no outcome yet — herdr run, see its terminal" ]
}

@test "--to orca or herdr without its CLI on PATH exits 1 naming it and creates nothing" {
  local d dirs=()
  while IFS= read -r d; do [ -x "$d/orca" ] || [ -x "$d/herdr" ] || dirs+=("$d"); done < <(tr ':' '\n' <<<"$PATH")
  local to
  for to in orca herdr; do
    run env PATH="$(IFS=:; echo "${dirs[*]}")" bash "$SCRIPT" dispatch report-cli --to "$to" -- claude
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$to not found"* ]]
  done
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 1 ]
}

@test "each destination defines only prepare, launch and live" {
  local f
  for f in "$REPO_ROOT"/skills/crew-afk/scripts/destinations/*.sh; do
    [ "$(env -i PATH="$PATH" bash --norc -c 'source "$1"; declare -F' _ "$f" | awk '{print $3}' | sort | paste -sd' ' -)" = "launch live prepare" ] || { echo "$f"; return 1; }
  done
}


@test "dispatch --to herdr while the slug's herdr run has no outcome and its pane exists exits 1 naming the pane and creates none" {
  stub_herdr
  bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}" >/dev/null
  logs="$WT/.coding-crew/solve-feature"
  echo kept > "$logs/run.log"
  before=$(cat "$logs/run.dest" "$logs/run.slug" "$logs/run.pane" "$logs/run.log")
  : > "$T/herdr-calls"
  run bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"a run for report-cli is still going (herdr pane w1:p1)"* ]]
  [[ "$output" == *"wait for it to end, or close that pane, then re-run"* ]]
  [ "$(grep -v '^pane get' "$T/herdr-calls")" = "" ]
  [ "$(cat "$logs/run.dest" "$logs/run.slug" "$logs/run.pane" "$logs/run.log")" = "$before" ]
}

@test "--to herdr on a workspace whose root pane runs an agent types the argv into a new tab's pane" {
  stub_herdr
  echo claude > "$T/herdr-root-agent"
  run bash "$SCRIPT" dispatch report-cli --to herdr -- claude "/solve-feature report-cli"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^tab create --workspace w1 ' "$T/herdr-calls"
  grep -qxF 'pane run w1:p2 claude /solve-feature\ report-cli ' "$T/herdr-calls"
  [ "$(cat "$WT/.coding-crew/solve-feature/run.pane")" = w1:p2 ]
}

OWT_LOGS() { echo "$T/orca-wt/app-report-cli/.coding-crew/solve-feature"; }

@test "dispatch --to orca while the slug's orca run has no outcome and its terminal is connected exits 1, reading orca's worktree" {
  stub_orca
  bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}" >/dev/null
  [ "$(cat "$(OWT_LOGS)/run.pane")" = h1 ]
  [ ! -e "$WT" ]
  : > "$T/orca-calls"
  run bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"a run for report-cli is still going (orca terminal h1): wait for it to end, or close that terminal, then re-run"* ]]
  [ "$(cat "$T/orca-calls")" = "terminal show --terminal h1 --json" ]
}

@test "a dispatch refuses across destinations and worktrees, and a refused one calls no prepare" {
  stub_orca
  stub_herdr
  # A live herdr run: --to local and --to orca refuse.
  bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}" >/dev/null
  : > "$T/herdr-calls"
  for to in local orca; do
    run bash "$SCRIPT" dispatch report-cli --to "$to" "${LAUNCH[@]}"
    [ "$status" -eq 1 ] || { echo "$to: $output"; return 1; }
    [[ "$output" == *"still going (herdr pane w1:p1)"* ]]
  done
  [ ! -e "$T/orca-calls" ] && [ ! -e "$T/claude-argv" ]
  ! grep -q '^worktree' "$T/herdr-calls"
  git -C "$MAIN" worktree remove --force "$WT"
  # A live local run: --to herdr and --to orca refuse.
  bash "$SCRIPT" dispatch report-cli "${LAUNCH[@]}" >/dev/null
  pid=$(cat "$WT/.coding-crew/solve-feature/run.pid")
  : > "$T/herdr-calls"
  for to in herdr orca; do
    run bash "$SCRIPT" dispatch report-cli --to "$to" "${LAUNCH[@]}"
    [ "$status" -eq 1 ] || { echo "$to: $output"; return 1; }
    [[ "$output" == *"still going (pid $pid): wait for it to end, then re-run"* ]]
  done
  [ ! -s "$T/herdr-calls" ] && [ ! -e "$T/orca-calls" ]
  [ ! -e "$T/orca-wt" ]
  [ "$(git -C "$MAIN" worktree list | wc -l)" -eq 2 ]
}

@test "a live orca run, in orca's own worktree, refuses --to local and --to herdr" {
  stub_orca
  stub_herdr
  bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}" >/dev/null
  for to in local herdr; do
    run bash "$SCRIPT" dispatch report-cli --to "$to" "${LAUNCH[@]}"
    [ "$status" -eq 1 ] || { echo "$to: $output"; return 1; }
    [[ "$output" == *"still going (orca terminal h1)"* ]]
  done
  [ ! -e "$WT" ] && [ ! -e "$T/herdr-calls" ]
}

@test "a re-dispatch reuses the worktree once the previous run wrote an outcome, or once its pane or terminal is gone" {
  stub_herdr
  bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}" >/dev/null
  echo 'ready pr=7' > "$WT/.coding-crew/solve-feature/outcome"
  run bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$WT" ]
  touch "$T/herdr-pane-gone"
  run bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c '^worktree create' "$T/herdr-calls")" -eq 1 ]
  stub_orca
  git -C "$MAIN" worktree remove --force "$WT"
  bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}" >/dev/null
  echo '{"ok":true,"result":{"terminal":{"handle":"h1","connected":true,"orphaned":true}}}' > "$T/orca-show"
  run bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(field worktree)" = "$T/orca-wt/app-report-cli" ]
  [ "$(grep -c '^worktree create' "$T/orca-calls")" -eq 1 ]
}

@test "a live query that fails other than with gone stops the dispatch with the CLI's stderr" {
  stub_herdr
  bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}" >/dev/null
  touch "$T/herdr-pane-fail"
  run bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *'server_down'* ]]
  [[ "$output" == *"if the pane is gone, delete $WT/.coding-crew/solve-feature/run.pane and re-run"* ]]
  git -C "$MAIN" worktree remove --force "$WT"
  stub_orca
  bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}" >/dev/null
  touch "$T/orca-show-fail"
  run bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"orca: server unreachable"* ]]
  [[ "$output" == *"if the terminal is gone, delete $(OWT_LOGS)/run.pane and re-run"* ]]
}

@test "status and wait report an interactive run whose pane is gone as ended, and a failing query as unknown" {
  export CREW_AFK_WAIT_INTERVAL=0.1
  stub_herdr
  bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}" >/dev/null
  touch "$T/herdr-pane-gone"
  run bash "$SCRIPT" status report-cli
  [ "$output" = "report-cli: ended without an outcome — its herdr terminal is gone; re-run /crew-afk report-cli --to herdr to continue" ]
  run bash "$SCRIPT" wait report-cli
  [ "$status" -eq 0 ] && [ "$output" = "report-cli: ended without an outcome — its herdr terminal is gone; re-run /crew-afk report-cli --to herdr to continue" ]
  rm "$T/herdr-pane-gone"; touch "$T/herdr-pane-fail"
  run bash "$SCRIPT" status
  [[ "$output" == 'report-cli: run state unknown — herdr query failed: {"error":{"code":"server_down"'* ]]
  run bash "$SCRIPT" wait report-cli
  [ "$status" -eq 0 ] && [[ "$output" == "report-cli: run state unknown — herdr query failed: "* ]]
  git -C "$MAIN" worktree remove --force "$WT"
  stub_orca
  bash "$SCRIPT" dispatch report-cli --to orca "${LAUNCH[@]}" >/dev/null
  echo '{"ok":true,"result":{"terminal":{"handle":"h1","connected":false,"orphaned":false}}}' > "$T/orca-show"
  run bash "$SCRIPT" wait report-cli
  [ "$output" = "report-cli: ended without an outcome — its orca terminal is gone; re-run /crew-afk report-cli --to orca to continue" ]
}

@test "a re-dispatch whose launch fails leaves no earlier run.pane, so the next dispatch is not blocked" {
  stub_herdr
  bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}" >/dev/null
  echo "ready pr=7" > "$WT/.coding-crew/solve-feature/outcome"
  touch "$T/herdr-run-fail"
  run bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ ! -e "$WT/.coding-crew/solve-feature/run.pane" ]
  run bash "$SCRIPT" status report-cli
  [[ "$output" == "report-cli: ended without an outcome — "* ]]
  rm "$T/herdr-run-fail"
  run bash "$SCRIPT" dispatch report-cli --to local "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "an interactive run with no run.pane, dispatched before it was recorded, does not block a dispatch" {
  stub_herdr
  bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}" >/dev/null
  rm "$WT/.coding-crew/solve-feature/run.pane"
  run bash "$SCRIPT" status report-cli
  [[ "$output" == "report-cli: ended without an outcome — "* ]]
  run bash "$SCRIPT" dispatch report-cli --to herdr "${LAUNCH[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
