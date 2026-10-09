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

bats_require_minimum_version 1.5.0
load helpers/render
load helpers/fake-docker

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/ensure-deps.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  # Physical path: the script resolves --dir (and derives MAIN_ROOT/marker/log paths from
  # it) with `pwd -P`, so on a host where $TEMP_DIR itself is a symlink or mount alias the
  # raw mktemp path differs textually from what the script prints while naming the same
  # directory. Matches crew-afk-receipts.bats / verify-worktree-docker.bats.
  TEMP_DIR=$(cd "$TEMP_DIR" && pwd -P)
  export TEMP_DIR
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  # No sprint unless a test opts in.
  unset TRACE_LOG SPRINT_DIR MAIN_ROOT CREW_DEPS CREW_DEP_INSTALL_SCRIPTS CREW_DOCKER_INSTALL CREW_INSTALL_DIR
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

# stub_docker_scripts_with_real_gen_override <docker-install-exit> [stdout] — same as
# stub_docker_scripts, but gen-override.sh is the real script rather than absent, so the
# override-generating calls in ensure-deps.sh have something real to exercise.
stub_docker_scripts_with_real_gen_override() {
  local install_exit="$1" install_out="${2:-}"
  local d="$TEMP_DIR/stub-docker-scripts-real-override"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho USE_DOCKER\n' > "$d/detect-mode.sh"
  {
    printf '#!/usr/bin/env bash\n'
    if [ -n "$install_out" ]; then
      printf "cat <<'STUBEOF'\n%s\nSTUBEOF\n" "$install_out"
    fi
    printf 'exit %s\n' "$install_exit"
  } > "$d/docker-install.sh"
  cp "$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"/skills/dep-install/scripts/{gen-override,manifest-fingerprint}.sh "$d/"
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

@test "a node_modules linked from the main checkout is stale, and installs, when the worktree's lockfile differs" {
  local main="$TEMP_DIR/main" wt="$TEMP_DIR/issue-wt"
  mkdir -p "$main/node_modules" "$wt"
  printf '{}\n' > "$main/package.json"; printf 'lock-A\n' > "$main/package-lock.json"
  printf '{}\n' > "$wt/package.json";   printf 'lock-B\n' > "$wt/package-lock.json"
  ln -s "$main/node_modules" "$wt/node_modules"
  export MAIN_ROOT="$main"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$wt"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: installed npm ci" ]
  [ ! -L "$wt/node_modules" ]

  # The same lockfile on both sides: the link is as good as an install.
  printf 'lock-A\n' > "$wt/package-lock.json"
  ln -s "$main/node_modules" "$wt/node_modules"
  run bash "$SCRIPT" --dir "$wt"
  [ "$(deps_line)" = "DEPS: present" ]
}

@test "run by hand (no MAIN_ROOT) in a linked worktree, the stale link is still found against the main checkout" {
  local wt="$TEMP_DIR/issue-wt"
  printf '{}\n' > "$WORK/package.json"; printf 'lock-A\n' > "$WORK/package-lock.json"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
  git -C "$WORK" worktree add -q -b issue "$wt"
  mkdir -p "$WORK/node_modules"
  printf 'lock-B\n' > "$wt/package-lock.json"
  ln -s "$WORK/node_modules" "$wt/node_modules"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$wt"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: installed npm ci" ]
  [ ! -L "$wt/node_modules" ]
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

@test "this repo - bats only, no manifest - is DEPS: none and exit 0" {
  local repo_root
  repo_root="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  # Else a live sprint in this checkout would get the DEPS line in its trace log.
  export TRACE_LOG="$TEMP_DIR/trace.log"
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

# ─── the discovered install override (.coding-crew/dev-commands.json's "install" field) ────
#
# discover-commands.sh / write-commands-cache.sh run once (bootstrap), before this script's own
# MAIN_ROOT call, and may cache a documented install command this script would otherwise never
# see (it deliberately never reads CLAUDE.md itself). When that cache names one, it wins over
# the mechanical Makefile-target/lockfile guess below.

@test "a documented install command in .coding-crew/dev-commands.json is used instead of host-install.sh" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.coding-crew"
  printf '{"install": "echo custom-install-ran > marker.txt"}' > "$WORK/.coding-crew/dev-commands.json"
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
  mkdir -p "$other/.coding-crew"
  printf '{"install": "pwd > here.txt"}' > "$other/.coding-crew/dev-commands.json"
  export MAIN_ROOT="$other"
  printf '{}\n' > "$WORK/package.json"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: installed"* ]]
  [ -f "$WORK/here.txt" ]
  [ "$(cat "$WORK/here.txt")" = "$(cd "$WORK" && pwd -P)" ]
}

@test "a null install in dev-commands.json falls back to host-install.sh unchanged" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.coding-crew"
  printf '{"test": "make test", "install": null}' > "$WORK/.coding-crew/dev-commands.json"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: installed npm ci" ]
}

@test "no dev-commands.json at all falls back to host-install.sh unchanged" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: installed npm ci" ]
}

@test "a documented install override runs even with no manifest the presence guard recognises" {
  # No package.json, no lockfile, no Makefile install/deps target — the presence guard's own
  # heuristic would otherwise call this DEPS: none before step 5 is ever reached.
  mkdir -p "$WORK/.coding-crew"
  printf '{"install": "echo custom-install-ran > marker.txt"}' > "$WORK/.coding-crew/dev-commands.json"
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: installed"* ]] || { echo "$output" >&2; return 1; }
  [ -f "$WORK/marker.txt" ]
}

@test "a documented install override does not prevent the presence guard from short-circuiting an already-present dep dir" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/node_modules" "$WORK/.coding-crew"
  printf '{"install": "echo SHOULD NOT RUN"}' > "$WORK/.coding-crew/dev-commands.json"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: present" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "a failing discovered install command is reported failed, with its own tail, and never re-guessed via host-install.sh" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.coding-crew"
  printf '{"install": "echo custom install boom >&2; exit 5"}' > "$WORK/.coding-crew/dev-commands.json"
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

# ─── docker mechanization: every worktree installs into the volumes its lockfiles name ──────
#
# The dependency volumes are named by a hash of the lockfiles, and docker-install.sh fills a volume
# only when it lacks its completion stamp. So every `--slug` call (an issue, `_baseline`,
# `_integration`) runs it and reports what it found; the one MAIN_ROOT call (no --slug) only
# records the mode, because no worktree's lockfiles are its own.

# stub_install_args_check <file> — a docker-install.sh stub that records its argv and prints a
# Running: line
stub_install_args_check() {
  local file="$1" d="$TEMP_DIR/stub-docker-argcheck"
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho USE_DOCKER\n' > "$d/detect-mode.sh"
  cat > "$d/docker-install.sh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$file"
echo "Running: docker compose run --rm app sh -c 'npm ci'"
exit 0
STUBEOF
  chmod +x "$d"/*.sh
  export CREW_DEP_INSTALL_SCRIPTS="$d"
}

@test "the MAIN_ROOT call (no --slug) only records the mode: no install command, no marker, DEPS: docker" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 0 "Running: docker compose run --rm app sh -c 'npm ci'"
  printf '#!/usr/bin/env bash\ntouch "%s/install-ran"\n' "$TEMP_DIR" > "$CREW_DEP_INSTALL_SCRIPTS/docker-install.sh"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [ ! -e "$TEMP_DIR/install-ran" ]
  [[ "$(cat "$WORK/.coding-crew/dev-commands.json")" == *'"install_mode": "docker"'* ]]
  [ ! -e "$WORK/.scratch/docker-install.done" ]
  [ ! -e "$WORK/.scratch/docker-install.fingerprint" ]
}

@test "the MAIN_ROOT call writes install_mode and docker_service to dev-commands.json, and writes no override" {
  printf '{}\n' > "$WORK/package.json"
  printf 'services:\n  app:\n    build: .\n' > "$WORK/docker-compose.yml"
  printf 'deps:\n\tdocker compose run --rm app npm ci\n' > "$WORK/Makefile"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts_with_real_gen_override 0
  cp "$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/detect-service.sh" "$CREW_DEP_INSTALL_SCRIPTS/"

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  cache="$(cat "$WORK/.coding-crew/dev-commands.json")"
  [[ "$cache" == *'"install_mode": "docker"'* ]]
  [[ "$cache" == *'"docker_service": "app"'* ]]
  [ ! -e "$WORK/.git/crew-compose.override.yml" ]
  [ ! -e "$WORK/docker-compose.override.yml" ]
}

@test "the MAIN_ROOT docker call deletes an older install's generated override and keeps a project's own" {
  printf '{}\n' > "$WORK/package.json"
  printf 'services:\n  app:\n    build: .\n' > "$WORK/docker-compose.yml"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts_with_real_gen_override 0

  # what an older gen-override.sh wrote: first line `name:`, volume keys wt_<PROJ_SLUG>_…
  printf 'name: work\nservices:\n  app:\n    volumes:\n      - wt_work_nm_root:/app/node_modules\nvolumes:\n  wt_work_nm_root:\n' \
    > "$WORK/docker-compose.override.yml"
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/docker-compose.override.yml" ]

  own='services:\n  app:\n    environment:\n      - MINE=1\nvolumes:\n  cache:\n'
  printf "$own" > "$WORK/docker-compose.override.yml"
  before="$(cksum < "$WORK/docker-compose.override.yml")"
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(cksum < "$WORK/docker-compose.override.yml")" = "$before" ]
}

@test "the MAIN_ROOT call caches its docker verdict to dev-commands.json a worker's own detect-mode.sh can read" {
  # This is the mechanism that survives a worker resolving a completely different install
  # of dep-install than the one this script found: unlike the per-call git-config write,
  # it is written exactly once (here) with nothing to race, and is a committed cache any copy
  # of detect-mode.sh can check regardless of where it lives — and unlike a .scratch file, it
  # survives to the next sprint too.
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 0

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(cat "$WORK/.coding-crew/dev-commands.json")" == *'"install_mode": "docker"'* ]]

  # A fresh detect-mode.sh call, unrelated to the stub above, with no git config set at
  # all — it must still say USE_DOCKER purely from the cache file.
  [ -z "$(git -C "$WORK" config --local agent.install-mode 2>/dev/null)" ] || \
    git -C "$WORK" config --local --unset agent.install-mode
  run bash "$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/detect-mode.sh" \
    --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "USE_DOCKER" ]
}

@test "the mode cache merge preserves sibling dev-commands.json fields instead of clobbering them" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  mkdir -p "$WORK/.coding-crew"
  printf '{"test": "npm test", "lint": null}\n' > "$WORK/.coding-crew/dev-commands.json"
  stub_docker_scripts 0

  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  cache="$(cat "$WORK/.coding-crew/dev-commands.json")"
  [[ "$cache" == *'"test": "npm test"'* ]]
  [[ "$cache" == *'"lint": null'* ]]
  [[ "$cache" == *'"install_mode": "docker"'* ]]
}

@test "a worktree call (--slug) runs docker-install.sh without --force and reports what it ran" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_install_args_check "$TEMP_DIR/args.txt"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker-installed docker compose run --rm app sh -c 'npm ci'" ]
  ! grep -qx -- "--force" "$TEMP_DIR/args.txt"
  grep -qx -- "--project-root" "$TEMP_DIR/args.txt"
  [ ! -e "$WORK/.scratch/docker-install.done" ]
}

@test "a worktree call (--slug) whose volumes already hold the install is DEPS: docker-present" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 0 "Present: /opt/app/node_modules/.crew-stamp found — the dependency volumes are already installed"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker-present" ]
}

@test "a worktree call (--slug) still runs docker-install.sh when a stale host node_modules is present" {
  # A host-side node_modules says nothing about the docker volumes the worktree's checks read.
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/node_modules"
  export MAIN_ROOT="$WORK"
  stub_install_args_check "$TEMP_DIR/args.txt"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: docker-installed"* ]] || { echo "$output" >&2; return 1; }
}

@test "a hand run with --slug but no sprint env and no --feature-slug exits 2 naming --feature-slug" {
  printf '{}\n' > "$WORK/package.json"
  run --separate-stderr bash "$SCRIPT" --dir "$WORK" --slug widget
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--feature-slug"* ]]
}

@test "a discovered install override is forwarded to docker-install.sh via --install-cmd" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.coding-crew"
  printf '{"install": "make deps"}' > "$WORK/.coding-crew/dev-commands.json"
  export MAIN_ROOT="$WORK"
  stub_install_args_check "$TEMP_DIR/docker-install-args.txt"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  grep -qx -- "--install-cmd" "$TEMP_DIR/docker-install-args.txt"
  grep -qx -- "make deps" "$TEMP_DIR/docker-install-args.txt"
  [[ "$(deps_line)" == "DEPS: docker-installed"* ]]
}

@test "no discovered install override omits --install-cmd from the docker-install.sh call" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_install_args_check "$TEMP_DIR/docker-install-args-none.txt"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  ! grep -qx -- "--install-cmd" "$TEMP_DIR/docker-install-args-none.txt"
}

@test "a discovered credential_target override is forwarded to docker-install.sh via --credential-target" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.coding-crew"
  printf '{"credential_target": ".npmrc"}' > "$WORK/.coding-crew/dev-commands.json"
  export MAIN_ROOT="$WORK"
  stub_install_args_check "$TEMP_DIR/docker-install-cred-args.txt"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  grep -qx -- "--credential-target" "$TEMP_DIR/docker-install-cred-args.txt"
  grep -qx -- ".npmrc" "$TEMP_DIR/docker-install-cred-args.txt"
}

@test "no discovered credential_target omits --credential-target from the docker-install.sh call" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_install_args_check "$TEMP_DIR/docker-install-cred-args-none.txt"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  ! grep -qx -- "--credential-target" "$TEMP_DIR/docker-install-cred-args-none.txt"
}

@test "a null credential_target in dev-commands.json omits --credential-target, same as absent" {
  printf '{}\n' > "$WORK/package.json"
  mkdir -p "$WORK/.coding-crew"
  printf '{"credential_target": null}' > "$WORK/.coding-crew/dev-commands.json"
  export MAIN_ROOT="$WORK"
  stub_install_args_check "$TEMP_DIR/docker-install-cred-args-null.txt"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  ! grep -qx -- "--credential-target" "$TEMP_DIR/docker-install-cred-args-null.txt"
}

@test "docker-install.sh exit 2 (nothing to do) is DEPS: docker, and the worktree still gets its override" {
  printf '{}\n' > "$WORK/package.json"
  printf 'services:\n  app:\n    build: .\n' > "$WORK/docker-compose.yml"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts_with_real_gen_override 2 "No compose file found"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [ -f "$WORK/.git/crew-compose.override.yml" ]
}

@test "docker-install.sh exit 5 (install cannot reach the shared volumes) is DEPS: failed with its reasons" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  stub_docker_scripts 5 "not through docker compose"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: failed"*"(exit 5)"* ]]
  [[ "$output" == *"not through docker compose"* ]]
}

@test "a failed docker install is DEPS: failed <cmd> (exit 3) (see <log>), with the tail, still exit 0" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"
  stub_docker_scripts 3 "Running: docker compose run --rm app sh -c 'npm ci'
npm ERR! boom"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget --stem 01-widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: failed docker compose run --rm app sh -c 'npm ci' (exit 3) (see $SPRINT_DIR/docker-install-01-widget.log)" ]
  [[ "$output" == *"npm ERR! boom"* ]]
  [[ "$output" != *"docker-failed"* ]]
}

@test "a failed docker install saves its full output under the sprint dir, named for the stem" {
  # Only the DEPS: line survives into the orchestrator's own log (Sprint.installDeps /
  # runWorker log the line, never the stderr this script prints alongside it) — so the
  # detail behind "failed" has to live on disk, at a path the line itself names.
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"
  stub_docker_scripts 3 "Running: docker compose run --rm app sh -c 'npm ci'
npm ERR! boom"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug _baseline --stem _baseline
  [ "$status" -eq 0 ]
  local log="$SPRINT_DIR/docker-install-_baseline.log"
  [ -f "$log" ]
  grep -q 'npm ERR! boom' "$log"
  [[ "$(deps_line)" == *"$log"* ]] || { echo "$output" >&2; return 1; }
}

@test "CREW_DOCKER_INSTALL=off rolls back to the always-deferred docker outcome" {
  printf '{}\n' > "$WORK/package.json"
  export MAIN_ROOT="$WORK"
  export CREW_DOCKER_INSTALL=off
  stub_docker_scripts 0 "SHOULD NOT RUN"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: docker" ]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

# ─── the real scripts, a fake docker that plays the volumes: B3 and B4 ────────────────────────

# two_worktrees — MAIN_ROOT=$WORK, a docker-mode repo with a committed lockfile, and two worktrees
# of it ($WT1, $WT2) that start identical.
two_worktrees() {
  local repo
  repo="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  printf '{"name":"x"}\n' > "$WORK/package.json"
  printf '{"lock":"A"}\n' > "$WORK/package-lock.json"
  printf 'services:\n  app:\n    build: .\n    volumes:\n      - .:/opt/app\n' > "$WORK/docker-compose.yml"
  git -C "$WORK" add -A
  git -C "$WORK" commit -q -m init
  git -C "$WORK" config --local agent.install-mode docker
  WT1="$TEMP_DIR/wt1"; WT2="$TEMP_DIR/wt2"
  git -C "$WORK" worktree add -q -b one "$WT1" HEAD
  git -C "$WORK" worktree add -q -b two "$WT2" HEAD
  export MAIN_ROOT="$WORK" CREW_DEP_INSTALL_SCRIPTS="$repo/skills/dep-install/scripts"
  install_fake_docker "$TEMP_DIR/stub" "$TEMP_DIR/fake"
  export PATH="$TEMP_DIR/stub:$PATH"
}

# volume_names <worktree> — the dependency volume names its override carries
volume_names() { grep -o 'name: wt_[A-Za-z0-9_]*' "$(git -C "$1" rev-parse --path-format=absolute --git-dir)/crew-compose.override.yml" | sed 's/^name: //'; }

@test "two worktrees with different lockfiles name different volumes, and each gets its own install" {
  two_worktrees
  printf '{"lock":"B"}\n' > "$WT2/package-lock.json"

  run bash "$SCRIPT" --dir "$WT1" --feature-slug demo --slug one
  [[ "$(deps_line)" == "DEPS: docker-installed"* ]] || { echo "$output" >&2; return 1; }
  run bash "$SCRIPT" --dir "$WT2" --feature-slug demo --slug two
  [[ "$(deps_line)" == "DEPS: docker-installed"* ]] || { echo "$output" >&2; return 1; }

  [ -n "$(volume_names "$WT1")" ]
  [ "$(volume_names "$WT1")" != "$(volume_names "$WT2")" ]
  [ "$(grep -c . "$TEMP_DIR/fake/install.calls")" -eq 2 ]
  [ "$(ls "$TEMP_DIR/fake/vols" | wc -l)" -eq 2 ]
}

@test "two worktrees with identical lockfiles name the same volumes: one install, then DEPS: docker-present" {
  two_worktrees

  run bash "$SCRIPT" --dir "$WT1" --feature-slug demo --slug one
  [[ "$(deps_line)" == "DEPS: docker-installed"* ]] || { echo "$output" >&2; return 1; }
  run bash "$SCRIPT" --dir "$WT2" --feature-slug demo --slug two
  [ "$(deps_line)" = "DEPS: docker-present" ] || { echo "$output" >&2; return 1; }

  [ "$(volume_names "$WT1")" = "$(volume_names "$WT2")" ]
  [ "$(grep -c . "$TEMP_DIR/fake/install.calls")" -eq 1 ]
  # nothing named docker-compose.override.yml in either tree, and no old-style markers
  [ ! -e "$WT1/docker-compose.override.yml" ] && [ ! -e "$WT2/docker-compose.override.yml" ]
  [ ! -e "$WORK/.scratch/docker-install.done" ] && [ ! -e "$WORK/.scratch/docker-install.fingerprint" ]
}

@test "a failing docker install leaves no stamp and reports DEPS: failed … (exit 3) (see <log>)" {
  two_worktrees
  export FAKE_NPM_RC=1
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"

  run bash "$SCRIPT" --dir "$WT1" --feature-slug demo --slug one --stem 01-one
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: failed "*"(exit 3) (see $SPRINT_DIR/docker-install-01-one.log)" ]] || { echo "$output" >&2; return 1; }
  [ -f "$SPRINT_DIR/docker-install-01-one.log" ]
  [ -z "$(find "$TEMP_DIR/fake/vols" -name '.crew-stamp' -o -name '.crew-lock')" ]
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

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  local log="$SPRINT_DIR/dispatch/widget/deps.log"
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
  mkdir -p "$WORK/.coding-crew"
  printf '{"install": "echo custom install boom >&2; exit 5"}' > "$WORK/.coding-crew/dev-commands.json"
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

@test "a sprint's CREW_INSTALL_DIR supplies dep-install's scripts, with no search" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "Running: from-install-dir"
  mkdir -p "$TEMP_DIR/install/dep-install"
  mv "$CREW_DEP_INSTALL_SCRIPTS" "$TEMP_DIR/install/dep-install/scripts"
  unset CREW_DEP_INSTALL_SCRIPTS
  CREW_INSTALL_DIR="$TEMP_DIR/install" run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(deps_line)" = "DEPS: installed from-install-dir" ] || { echo "$output"; return 1; }
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

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [ -f "$SPRINT_DIR/dispatch/widget/deps.skip" ]

  # Second round: the probe is not repeated, and the cached outcome is reported.
  stub_scripts USE_HOST 0 "SHOULD NOT RUN"
  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [[ "$(deps_line)" == "DEPS: failed"* ]]
  [[ "$output" != *"SHOULD NOT RUN"* ]]
}

@test "a successful install writes the ok marker" {
  printf '{}\n' > "$WORK/package.json"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch"
  stub_scripts USE_HOST 0 "Running: npm ci"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [ -f "$SPRINT_DIR/dispatch/widget/deps.ok" ]
  [ ! -f "$SPRINT_DIR/dispatch/widget/deps.skip" ]
}

@test "the marker is a cache, never the guard: a present dep dir wins over a skip marker" {
  printf '{}\n' > "$WORK/package.json"
  export SPRINT_DIR="$TEMP_DIR/sprint"
  mkdir -p "$SPRINT_DIR/dispatch/widget"
  printf 'none\n' > "$SPRINT_DIR/dispatch/widget/deps.skip"
  mkdir -p "$WORK/node_modules"

  run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
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

@test "inside a dispatched agent, an inherited MAIN_ROOT's sprint gets no trace and no marker" {
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "Running: npm ci"
  local live="$TEMP_DIR/live"
  mkdir -p "$live/.scratch"
  git -C "$live" init -q
  printf 'export TRACE_LOG="%s/live.log"\nexport SPRINT_DIR="%s/sprint"\n' "$TEMP_DIR" "$TEMP_DIR" > "$live/.scratch/sprint.env"
  MAIN_ROOT="$live" CREW_ORCHESTRATED=1 run bash "$SCRIPT" --dir "$WORK" --feature-slug demo --slug widget
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/live.log" ]
  [ ! -e "$TEMP_DIR/sprint" ]
}

@test "the trace follows --dir's sprint, not the caller's working directory" {
  # Run from inside another repo with a live sprint: its trace log must not get this
  # script's DEPS line — the marker lookup already resolves the sprint from --dir.
  printf '{}\n' > "$WORK/package.json"
  stub_scripts USE_HOST 0 "Running: npm ci"
  local decoy="$TEMP_DIR/decoy"
  mkdir -p "$decoy/.scratch"
  git -C "$decoy" init -q
  printf 'export TRACE_LOG="%s/decoy.log"\n' "$TEMP_DIR" > "$decoy/.scratch/sprint.env"
  cd "$decoy"
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/decoy.log" ]
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

@test ".claude/rules/crew-afk.md lists the script with its one-clause rationale and the pipeline order" {
  local f="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/.claude/rules/crew-afk.md"
  grep -q 'ensure-deps.sh' "$f"
  # Why mechanism and not a worker skill read: it is the only layer covering the gate.
  grep -q 'verify-worktree.sh' "$f"
  grep -qi 'cannot invoke a skill' "$f"
  # And the order it sits in.
  grep -qi 'deps' "$f"
  grep -q 'worktreeinclude' "$f"
}

@test "no launcher SKILL.md mentions the script, and every launcher is still under the word budget" {
  local repo="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  local p body words
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$(afk_variant "$p")"
    ! grep -q 'ensure-deps' "$body" || {
      echo "$p launcher names ensure-deps.sh" >&2; return 1; }
    words=$(wc -w < "$body")
    [ "$words" -lt "$AFK_LAUNCHER_WORD_BUDGET" ] || { echo "$p launcher is $words words" >&2; return 1; }
  done
}
