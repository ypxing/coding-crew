#!/usr/bin/env bats

# ensure-deps.sh — the mechanical half of dependency provisioning.
#
# The judgement half (generating a docker override) stays in the dep-install skill, because
# it is judgement. What is left has no judgement in it at all: is a dep dir there, and if
# not, run the project's own install command. That belongs in a script the orchestrator
# runs, for two reasons a worker skill cannot cover — it costs zero tokens per issue, and
# it runs before verify-worktree.sh, which is a gate and cannot invoke a skill.
#
# The contract these tests pin: exactly one `DEPS:` line, and always exit 0. A repo with no
# dependency step must not stall a sprint, and a failed install is diagnosed by the check
# that follows it, never by this script's exit code.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/ensure-deps.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  # No sprint unless a test opts in.
  unset TRACE_LOG SPRINT_DIR MAIN_ROOT CREW_DEPS CREW_DEP_INSTALL_SCRIPTS CREW_DOCKER_INSTALL
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# stub_scripts <detect-output> <host-exit> [host-stdout] — a fake dep-install scripts dir,
# so the install-outcome cases do not depend on a real package manager being present.
stub_scripts() {
  local mode="$1" host_exit="$2" host_out="${3:-}"
  local d="$TEMP_DIR/stub-scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho %s\n' "$mode" > "$d/detect-mode.sh"
  {
    printf '#!/usr/bin/env bash\n'
    if [ -n "$host_out" ]; then
      printf "cat <<'STUBEOF'\n%s\nSTUBEOF\n" "$host_out"
    fi
    printf 'exit %s\n' "$host_exit"
  } > "$d/host-install.sh"
  chmod +x "$d"/*.sh
  export CREW_DEP_INSTALL_SCRIPTS="$d"
}

# stub_docker_scripts <docker-install-exit> [docker-install-stdout] — detect-mode.sh says
# USE_DOCKER, docker-install.sh is a stub so the docker mechanization tests do not depend
# on a real docker daemon.
stub_docker_scripts() {
  local install_exit="$1" install_out="${2:-}"
  local d="$TEMP_DIR/stub-docker-scripts"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho USE_DOCKER\n' > "$d/detect-mode.sh"
  {
    printf '#!/usr/bin/env bash\n'
    if [ -n "$install_out" ]; then
      printf "cat <<'STUBEOF'\n%s\nSTUBEOF\n" "$install_out"
    fi
    printf 'exit %s\n' "$install_exit"
  } > "$d/docker-install.sh"
  chmod +x "$d"/*.sh
  export CREW_DEP_INSTALL_SCRIPTS="$d"
}

# deps_line — the single DEPS: line the script is allowed to print
deps_line() {
  printf '%s\n' "$output" | grep '^DEPS:' || true
}

# ─── the presence guard ──────────────────────────────────────────────────────

@test "an existing dep dir is DEPS: present, and no install command runs" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/node_modules"
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: present" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "the presence guard covers node_modules, .venv and vendor/bundle" {
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"
  local manifest depdir
  for pair in "package.json:node_modules" "requirements.txt:.venv" "Gemfile:vendor/bundle"; do
    manifest="${pair%%:*}"; depdir="${pair##*:}"
    local d="$TEMP_DIR/present-$(echo "$depdir" | tr '/' '-')"
    mkdir -p "$d/$depdir"
    : > "$d/$manifest"
    run bash "$SCRIPT" --dir "$d"
    [ "$status" -eq 0 ]
    [ "$(deps_line)" = "DEPS: present" ] || {
      echo "$depdir did not read as present: $output" >&2; return 1; }
  done
}

@test "a repo with no manifest is DEPS: none, not a failure" {
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: none" ]
}

@test "this repo — bats only, no manifest — is DEPS: none and exit 0" {
  local repo_root
  repo_root="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  run bash "$SCRIPT" --dir "$repo_root"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: none" ]
}

# ─── the install path ────────────────────────────────────────────────────────

@test "a fresh worktree with a package-lock.json and no node_modules is DEPS: installed" {
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  # Pinned to this source tree's own dep-install scripts, not whatever a contributor's local
  # .coding-crew self-install happens to have on disk (_find_dep_scripts prefers that over
  # skills/dep-install/scripts when neither is stubbed) — otherwise this test's outcome
  # depends on which release .coding-crew was last installed from, not on this source.
  export CREW_DEP_INSTALL_SCRIPTS="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
  cat > "$WORK/package.json" <<'JSON'
{ "name": "fixture", "version": "1.0.0", "private": true }
JSON
  cat > "$WORK/package-lock.json" <<'JSON'
{
  "name": "fixture",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": { "": { "name": "fixture", "version": "1.0.0" } }
}
JSON
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: installed"* ]] || { echo "$output" >&2; return 1; }
  [[ "$(deps_line)" == *"npm ci"* ]]
}

@test "host-install.sh is invoked with --main-root, so it can honor an existing MAIN_ROOT .env" {
  printf '{}\n' > "$WORK/package.json"
  local d="$TEMP_DIR/stub-argcheck"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho USE_HOST\n' > "$d/detect-mode.sh"
  cat > "$d/host-install.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEMP_DIR/host-install-args.txt"
exit 2
STUBEOF
  chmod +x "$d"/*.sh
  export CREW_DEP_INSTALL_SCRIPTS="$d"
  local other="$TEMP_DIR/other-root"
  mkdir -p "$other"
  export MAIN_ROOT="$other"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  grep -qx -- "--main-root" "$TEMP_DIR/host-install-args.txt"
  grep -qx -- "$other" "$TEMP_DIR/host-install-args.txt"
}

# ─── the discovered install override (.scratch/commands.json's "install" field) ────────────
#
# discover-commands.sh / write-commands-cache.sh run once per sprint, before this script's own
# MAIN_ROOT call, and may cache a documented install command this script would otherwise never
# see (it deliberately never reads CLAUDE.md itself). When that cache names one, it wins over
# the mechanical Makefile-target/lockfile guess below.

@test "a documented install command in .scratch/commands.json is used instead of host-install.sh" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.scratch"
  printf '{"sourceHash": "x", "install": "echo custom-install-ran > marker.txt"}' > "$WORK/.scratch/commands.json"
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: installed"* ]] || { echo "$output" >&2; return 1; }
  [[ "$(deps_line)" == *"echo custom-install-ran"* ]]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
  [ -f "$WORK/marker.txt" ]
}

@test "the discovered install command runs from --dir, not from MAIN_ROOT" {
  local other="$TEMP_DIR/other-root"
  mkdir -p "$other/.scratch"
  printf '{"sourceHash": "x", "install": "pwd > here.txt"}' > "$other/.scratch/commands.json"
  export MAIN_ROOT="$other"
  printf '{}\n' > "$WORK/package.json"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: installed"* ]]
  [ -f "$WORK/here.txt" ]
  [ "$(cat "$WORK/here.txt")" = "$(cd "$WORK" && pwd -P)" ]
}

@test "a null install in commands.json falls back to host-install.sh unchanged" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.scratch"
  printf '{"sourceHash": "x", "test": "make test", "install": null}' > "$WORK/.scratch/commands.json"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: installed npm ci" ]
}

@test "no commands.json at all falls back to host-install.sh unchanged" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: installed npm ci" ]
}

@test "a documented install override runs even with no manifest the presence guard recognises" {
  # No package.json, no lockfile, no Makefile install/deps target — the presence guard's own
  # heuristic would otherwise call this DEPS: none before step 5 is ever reached.
  mkdir -p "$WORK/.scratch"
  printf '{"sourceHash": "x", "install": "echo custom-install-ran > marker.txt"}' > "$WORK/.scratch/commands.json"
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: installed"* ]] || { echo "$output" >&2; return 1; }
  [ -f "$WORK/marker.txt" ]
}

@test "a documented install override does not prevent the presence guard from short-circuiting an already-present dep dir" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/node_modules" "$WORK/.scratch"
  printf '{"sourceHash": "x", "install": "echo SHOULD NOT RUN"}' > "$WORK/.scratch/commands.json"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: present" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "a failing discovered install command is reported failed, with its own tail, and never re-guessed via host-install.sh" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.scratch"
  printf '{"sourceHash": "x", "install": "echo custom install boom >&2; exit 5"}' > "$WORK/.scratch/commands.json"
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: failed"* ]]
  [[ "$(deps_line)" == *"exit 5"* ]]
  [[ "$output" == *"custom install boom"* ]]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "docker mode is deferred to the worker: DEPS: docker, exit 0, no install" {
  printf '{}\n' > "$WORK/package.json"
  git -C "$WORK" config --local agent.install-mode docker
  # Real scripts, so this asserts detect-mode.sh's own answer, not a stub's.
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [ ! -d "$WORK/node_modules" ]
}

@test "a docker verdict reached only via the stub is persisted for the worker to read" {
  # Simulates detect-mode.sh concluding USE_DOCKER via its Makefile heuristic, with no
  # explicit agent.install-mode ever set and no override file present — the case that
  # used to leave solve-issue's own up-front check with nothing to read, so it silently
  # fell back to host mode and the worktree never got deps in either mode.
  printf '{}\n' > "$WORK/package.json"
  [ -z "$(git -C "$WORK" config --local agent.install-mode 2>/dev/null)" ]
  stub_scripts USE_DOCKER 0

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [ "$(git -C "$WORK" config --local agent.install-mode)" = "docker" ]
}

# ─── docker mechanization: the one MAIN_ROOT call warms the shared volume ─────────────────
#
# Named volumes are shared across every worktree of a MAIN_ROOT by design — that is the whole
# point of caching deps once instead of once per worktree — so the install itself must run
# exactly once. `--slug` is the signal: absent means "the one MAIN_ROOT call", present means
# "a worktree, only ever check the shared marker".

@test "the MAIN_ROOT call (no --slug) runs docker-install.sh and writes the marker" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 0 "Running: docker compose run --rm app sh -c 'npm ci'"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: docker-installed"* ]] || { echo "$output" >&2; return 1; }
  [[ "$(deps_line)" == *"npm ci"* ]]
  [ -f "$WORK/.scratch/docker-install.done" ]
}

@test "the MAIN_ROOT call still runs docker-install.sh when a stale host node_modules is present" {
  # A host-side node_modules can predate .worktreeinclude excluding it, or come from a
  # contributor's own local install, in a project that is otherwise docker-mode. The
  # presence guard must not read that as "nothing to do" and skip warming the docker
  # volume — that is the only place docker-compose.override.yml gets generated.
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/node_modules"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 0 "Running: docker compose run --rm app sh -c 'npm ci'"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: docker-installed"* ]] || { echo "$output" >&2; return 1; }
  [ -f "$WORK/.scratch/docker-install.done" ]
}

@test "a worktree call (--slug) after the marker exists is DEPS: docker-present, no install" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  mkdir -p "$WORK/.scratch"
  echo "npm ci" > "$WORK/.scratch/docker-install.done"
  stub_docker_scripts 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker-present" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "a worktree call (--slug) with no marker yet is still DEPS: docker, deferred" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
  [ ! -f "$WORK/.scratch/docker-install.done" ]
}

@test "docker-install.sh exit 2 (nothing to do) is DEPS: docker, not a new outcome" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 2 "No compose file found"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [ ! -f "$WORK/.scratch/docker-install.done" ]
}

@test "docker-install.sh exit 4 (lock busy) defers rather than blocks the round" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 4 "lock busy"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
}

@test "a failed docker install is advisory: DEPS: docker-failed with the tail, still exit 0" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 3 "Running: docker compose run --rm app sh -c 'npm ci'
npm ERR! boom"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: docker-failed"* ]]
  [[ "$(deps_line)" == *"exit 3"* ]]
  [[ "$output" == *"npm ERR! boom"* ]]
  [ ! -f "$WORK/.scratch/docker-install.done" ]
}

@test "a failed docker install persists the full output to .scratch/docker-install.log, and the line names it" {
  # Only the DEPS: line survives into the orchestrator's own log (Sprint.installDeps /
  # runWorker log the line, never the stderr this script prints alongside it) — so the
  # detail behind "docker-failed" has to live on disk, at a path the line itself names.
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 3 "Running: docker compose run --rm app sh -c 'npm ci'
npm ERR! boom"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  local log="$WORK/.scratch/docker-install.log"
  [ -f "$log" ]
  grep -q 'npm ERR! boom' "$log"
  [[ "$(deps_line)" == *"$log"* ]] || { echo "$output" >&2; return 1; }
}

@test "CREW_DOCKER_INSTALL=off rolls back to the always-deferred docker outcome" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  export CREW_DOCKER_INSTALL=off
  stub_docker_scripts 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "the marker is scoped to MAIN_ROOT, not to a feature slug: reused across sprints" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  mkdir -p "$WORK/.scratch"
  echo "npm ci" > "$WORK/.scratch/docker-install.done"
  stub_docker_scripts 0 "SHOULD NOT RUN"

  # Two different feature sprints against the same MAIN_ROOT, distinguished only by SPRINT_DIR.
  export SPRINT_DIR="$TEMP_DIR/sprint-a"
  mkdir -p "$SPRINT_DIR/dispatch"
  run bash "$SCRIPT" --dir "$WORK" --slug widget-a
  [ "$(deps_line)" = "DEPS: docker-present" ]

  export SPRINT_DIR="$TEMP_DIR/sprint-b"
  mkdir -p "$SPRINT_DIR/dispatch"
  run bash "$SCRIPT" --dir "$WORK" --slug widget-b
  [ "$(deps_line)" = "DEPS: docker-present" ]
}

@test "a failing install is advisory: DEPS: failed with the tail, still exit 0" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 3 "npm ERR! boom"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: failed"* ]]
  [[ "$(deps_line)" == *"exit 3"* ]]
  [[ "$output" == *"npm ERR! boom"* ]]
}

@test "a failed host install persists the full output next to the --slug marker, and the line names it" {
  printf '{}\n' > "$WORK/package.json"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"
  stub_scripts USE_HOST 3 "npm ERR! boom"

  run bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 0 ]
  local log="$SPRINT_DIR/dispatch/widget.deps.log"
  [ -f "$log" ]
  grep -q 'npm ERR! boom' "$log"
  [[ "$(deps_line)" == *"$log"* ]] || { echo "$output" >&2; return 1; }
}

@test "a failed host install with no sprint persists the full output under --dir's own .scratch" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 3 "npm ERR! boom"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  local log="$WORK/.scratch/deps-install.log"
  [ -f "$log" ]
  grep -q 'npm ERR! boom' "$log"
  [[ "$(deps_line)" == *"$log"* ]] || { echo "$output" >&2; return 1; }
}

@test "a failing discovered install command also persists its full output, named in the line" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.scratch"
  printf '{"sourceHash": "x", "install": "echo custom install boom >&2; exit 5"}' > "$WORK/.scratch/commands.json"
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  local log="$WORK/.scratch/deps-install.log"
  [ -f "$log" ]
  grep -q 'custom install boom' "$log"
  [[ "$(deps_line)" == *"$log"* ]] || { echo "$output" >&2; return 1; }
}

@test "host-install exit 2 (no install method) is DEPS: none" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 2 "No install method found"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: none" ]
}

@test "a run with no dep-install scripts anywhere is DEPS: none" {
  printf '{}\n' > "$WORK/package.json"
  export CREW_DEP_INSTALL_SCRIPTS="$TEMP_DIR/nowhere"
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: none" ]
}

# ─── idempotence and the escape hatch ────────────────────────────────────────

@test "a second run is a no-op with the same exit code" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  local first="$(deps_line)"
  mkdir -p "$WORK/node_modules"   # what a real install would have left behind

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: present" ]
  [[ "$first" == "DEPS: installed"* ]]
}

@test "CREW_DEPS=off skips everything and exits 0" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"
  export CREW_DEPS=off

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: skipped" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "exactly one DEPS: line is printed, even with a multi-line failure tail" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 3 "line one
line two"
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  local count
  count=$(printf '%s\n' "$output" | grep -c '^DEPS:')
  [ "$count" -eq 1 ]
  [[ "$output" == *"line two"* ]]
}

# ─── the marker cache ────────────────────────────────────────────────────────

@test "--slug writes a marker so a none/failed probe is not repeated every round" {
  printf '{}\n' > "$WORK/package.json"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"
  stub_scripts USE_HOST 3 "boom"

  run bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 0 ]
  [ -f "$SPRINT_DIR/dispatch/widget.deps.skip" ]

  # Second round: the probe is not repeated, and the cached outcome is reported.
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"
  run bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: failed"* ]]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "a successful install writes the ok marker" {
  printf '{}\n' > "$WORK/package.json"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 0 ]
  [ -f "$SPRINT_DIR/dispatch/widget.deps.ok" ]
  [ ! -f "$SPRINT_DIR/dispatch/widget.deps.skip" ]
}

@test "the marker is a cache, never the guard: a present dep dir wins over a skip marker" {
  printf '{}\n' > "$WORK/package.json"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"
  printf 'none\n' > "$SPRINT_DIR/dispatch/widget.deps.skip"
  mkdir -p "$WORK/node_modules"

  run bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: present" ]
}

# ─── tracing ─────────────────────────────────────────────────────────────────

@test "the outcome is traced with a DEPS marker when a sprint is present" {
  printf '{}\n' > "$WORK/package.json"
  export TRACE_LOG="$TEMP_DIR/trace.log"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ -f "$TRACE_LOG" ]
  grep -q '\[DEPS\]' "$TRACE_LOG"
  grep -q 'installed' "$TRACE_LOG"
}

@test "running outside a sprint works and traces nothing" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "Running: npm ci"
  # No TRACE_LOG, no SPRINT_DIR, and the dir's repo has no .scratch/sprint.env.
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: installed"* ]]
  [ ! -e "$WORK/.scratch" ]
  run bash -c "find '$TEMP_DIR' -name 'orchestrator.log' | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "0" ]
}

# ─── usage ───────────────────────────────────────────────────────────────────

@test "--dir is required, and a bad flag is a usage error" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --dir "$WORK" --nope
  [ "$status" -ne 0 ]
}

@test "a --dir that does not exist is a usage error, not a silent pass" {
  run bash "$SCRIPT" --dir "$TEMP_DIR/absent"
  [ "$status" -ne 0 ]
}

@test "the script is shipped executable and installs with the crew-afk skill" {
  [ -x "$SCRIPT" ]
  local target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target"
  git -C "$target" init -q -b main
  TARGET_REPO="$target" run bash "$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/install.sh" pi --skill crew-afk
  [ "$status" -eq 0 ]
  [ -f "$target/.pi/skills/crew-afk/scripts/ensure-deps.sh" ]
}

# ─── documented where the pipeline is documented ─────────────────────────────
#
# The decision is only half-made until the reason survives it: the failure-triggered
# CHANGELOG entry reads as the whole policy, and after this feature it is one half of a
# pair — eager where a gate cannot retry, lazy where a human can.

@test "CLAUDE.md lists the script with its one-clause rationale and the pipeline order" {
  local f="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/CLAUDE.md"
  grep -q 'ensure-deps.sh' "$f"
  # Why mechanism and not a worker skill read: it is the only layer covering the gate.
  grep -q 'verify-worktree.sh' "$f"
  grep -qi 'cannot invoke a skill' "$f"
  # And the order it sits in.
  grep -qi 'deps' "$f"
  grep -q 'worktreeinclude' "$f"
}

@test "no launcher SKILL.md mentions the script, and every launcher is still under 500 words" {
  local repo="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  local p body words
  for p in pi codex claude copilot; do
    body="$repo/skills/crew-afk/$p.SKILL.md"
    ! grep -q 'ensure-deps' "$body" || {
      echo "$p launcher names ensure-deps.sh" >&2; return 1; }
    words=$(wc -w < "$body")
    [ "$words" -lt 500 ] || { echo "$p launcher is $words words" >&2; return 1; }
  done
}
