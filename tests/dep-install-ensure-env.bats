#!/usr/bin/env bats

# ensure-env.sh — steps 0b-c of docker-install.md. Pins the "always exits 0, .env exists
# after it runs" contract, including the case a dangling symlink is already at .env (a
# stale .worktreeinclude link whose target no longer resolves): `cp`/`touch` on a dangling
# symlink either refuse ("not writing through dangling symlink") or resurrect whatever the
# broken link used to point at, so the script must clear it before creating .env fresh.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks/ensure-env.sh"

# make_dangling_symlink <link> — a symlink whose target doesn't exist, for tests that need
# ensure-env.sh to clear one. Creating a symlink to a target that doesn't exist has nothing
# for Windows/MSYS's own copy-fallback to fall back to (unlike a symlink to a real file,
# which that fallback silently substitutes even without symlink privilege), so `ln -s` fails
# outright there; skip in that case rather than assert on a dangling symlink this platform
# can't produce.
make_dangling_symlink() {
  ln -s "$(dirname "$1")/nonexistent-target" "$1" 2>/dev/null \
    || skip "this platform cannot create symlinks; a dangling symlink can't occur here"
}

setup() {
  PROJECT=$(mktemp -d)
  export PROJECT
}

teardown() {
  rm -rf "$PROJECT"
}

@test "creates .env from .env.example when neither exists yet" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "creates an empty .env when there is no .env.example" {
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
}

@test "leaves an existing real .env untouched" {
  echo "REAL=1" > "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}

@test "clears a dangling .env symlink and creates a real .env from .env.example" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  make_dangling_symlink "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "clears a dangling .env symlink and creates a real empty .env with no .env.example" {
  make_dangling_symlink "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
}

@test "leaves a valid (resolving) .env symlink untouched" {
  echo "REAL=1" > "$PROJECT/.env.actual"
  ln -s "$PROJECT/.env.actual" "$PROJECT/.env" 2>/dev/null \
    || skip "this platform cannot create symlinks; a resolving symlink can't occur here"
  [ -L "$PROJECT/.env" ] \
    || skip "this platform's ln -s silently substituted a copy; a resolving symlink can't occur here"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ -L "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}

@test "a worktree gets its own .env, generated in the worktree; --main-root is an unknown argument" {
  MAIN=$(mktemp -d)
  echo "SECRET=real" > "$MAIN/.env"
  echo "FOO=bar" > "$PROJECT/.env.example"
  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 1 ]
  [ ! -e "$PROJECT/.env" ]
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ ! -L "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
  rm -rf "$MAIN"
}

# ─── .env is always excluded from the git repo it lands in ─────────────────────────────
#
# A `git add -A` must never pick up a .env this script created.

# ─── the discovered env override (.coding-crew/dev-commands.json's "env" field) ────────────
#
# discover-commands.sh / write-commands-cache.sh run once (bootstrap) and may cache a
# documented .env-bootstrap command this script would otherwise never see (it deliberately
# never reads CLAUDE.md itself). When that cache names one, it wins over the mechanical
# .env.example-or-empty convention below.

@test "a documented env command in .coding-crew/dev-commands.json is used instead of the .env.example convention" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": "echo CUSTOM=1 > .env"}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "CUSTOM=1" ]
  [[ "$output" == *"discovered"* ]]
}

@test "a null env in dev-commands.json falls back to the .env.example convention unchanged" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": null}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "no dev-commands.json at all falls back to the .env.example convention unchanged" {
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

# ─── the Makefile env-target scan, tried between the discovered override and the mechanical
# convention — the same safety net host-install.sh's own install/deps target scan already
# gives `install`, now given to `env` too: the discovery model is told it MUST check any
# Makefile before answering null, but that is a nudge, not a guarantee.

@test "a null env in dev-commands.json falls back to a Makefile env target before .env.example" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": null}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"
  cat > "$PROJECT/Makefile" <<'MK'
env:
	echo MAKE_ENV=1 > .env
MK

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "MAKE_ENV=1" ]
  [[ "$output" == *"Makefile target"* ]]
}

@test "no dev-commands.json at all still falls back to a Makefile env target before .env.example" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  cat > "$PROJECT/Makefile" <<'MK'
env:
	echo MAKE_ENV=1 > .env
MK

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.env")" = "MAKE_ENV=1" ]
}

@test "a Makefile .env file-target is recognised the same as a phony env target" {
  cat > "$PROJECT/Makefile" <<'MK'
.env:
	echo MAKE_DOTENV=1 > .env
MK

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.env")" = "MAKE_DOTENV=1" ]
}

@test "a Makefile env target invoking docker is skipped, falling through to .env.example" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  cat > "$PROJECT/Makefile" <<'MK'
env:
	docker compose run --rm app make env
MK

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "a discovered env override still wins over a Makefile env target" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": "echo CUSTOM=1 > .env"}' > "$PROJECT/.coding-crew/dev-commands.json"
  cat > "$PROJECT/Makefile" <<'MK'
env:
	echo MAKE_ENV=1 > .env
MK

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.env")" = "CUSTOM=1" ]
}

@test "a Makefile with no env-shaped target falls through to .env.example unchanged" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  cat > "$PROJECT/Makefile" <<'MK'
build:
	echo building
MK

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "a failing discovered env command still leaves a real .env behind via the mechanical fallback" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": "echo custom env boom >&2; exit 5"}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "a discovered env command that exits 0 but never creates .env falls back to the mechanical convention" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": "true"}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "an existing real .env still wins over a discovered env command" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": "echo SHOULD_NOT_RUN=1 > .env"}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "REAL=1" > "$PROJECT/.env"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}

@test "a freshly generated .env is added to .git/info/exclude, not the project's own .gitignore" {
  git -C "$PROJECT" init -q
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  grep -qx '.env' "$PROJECT/.git/info/exclude"
  [ ! -f "$PROJECT/.gitignore" ]
}

@test "an existing real .env is left alone: no exclude entry added for a run that changed nothing" {
  git -C "$PROJECT" init -q
  echo "REAL=1" > "$PROJECT/.env"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  if [ -f "$PROJECT/.git/info/exclude" ]; then
    ! grep -qx '.env' "$PROJECT/.git/info/exclude"
  fi
}

# ─── --credential-target: a full command (e.g. "make _registry"), evaled directly, guarded
# against docker-in-docker nesting the same way docker-install.sh's own --install-cmd is ─────

@test "--credential-target runs the discovered command and generates the credential file" {
  cat > "$PROJECT/Makefile" <<'MK'
.npmrc:
	echo "TOKEN=x" > .npmrc
MK

  run bash "$SCRIPT" --project-root "$PROJECT" --credential-target "make .npmrc"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.npmrc" ]
  [[ "$output" == *"ran discovered credential_target"* ]]
}

@test "a --credential-target command that already invokes docker is skipped, never eval'd" {
  run bash "$SCRIPT" --project-root "$PROJECT" --credential-target "docker compose run --rm app make _registry"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already invokes docker"* ]]
  [ ! -f "$PROJECT/.npmrc" ]
}

@test "a --credential-target bare 'make <target>' whose recipe invokes docker is also skipped" {
  cat > "$PROJECT/Makefile" <<'MK'
_registry:
	docker compose run --rm app ./gen-creds.sh
MK

  run bash "$SCRIPT" --project-root "$PROJECT" --credential-target "make _registry"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already invokes docker"* ]]
}

@test "a failing --credential-target command is reported, not fatal" {
  run bash "$SCRIPT" --project-root "$PROJECT" --credential-target "exit 5"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed, falling back to template expansion"* ]]
}
