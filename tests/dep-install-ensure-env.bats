#!/usr/bin/env bats

# ensure-env.sh — steps 0b-c of docker-install.md. Pins the "always exits 0, .env exists
# after it runs" contract, including the case a dangling symlink is already at .env (a
# stale .worktreeinclude link whose target no longer resolves): `cp`/`touch` on a dangling
# symlink either refuse ("not writing through dangling symlink") or resurrect whatever the
# broken link used to point at, so the script must clear it before creating .env fresh.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/ensure-env.sh"

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
  ln -s "$PROJECT/nonexistent-target" "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "clears a dangling .env symlink and creates a real empty .env with no .env.example" {
  ln -s "$PROJECT/nonexistent-target" "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
}

@test "leaves a valid (resolving) .env symlink untouched" {
  echo "REAL=1" > "$PROJECT/.env.actual"
  ln -s "$PROJECT/.env.actual" "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ -L "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}

# ─── --main-root: honor an existing MAIN_ROOT .env instead of generating a new one ─────────
#
# PROJECT_ROOT is a worktree; MAIN_ROOT is the shared checkout. A real .env already at
# MAIN_ROOT must win over PROJECT_ROOT's own .env.example — regenerating independently per
# worktree would silently diverge from whatever secrets are already in the real .env.

@test "--main-root: an existing MAIN_ROOT .env is linked into PROJECT_ROOT, not regenerated" {
  MAIN=$(mktemp -d)
  echo "SECRET=real" > "$MAIN/.env"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MAIN_ROOT"* || "$output" == *"Linked"* ]]
  [ -L "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "SECRET=real" ]
  [ "$(cat "$MAIN/.env")" = "SECRET=real" ]
  rm -rf "$MAIN"
}

@test "--main-root: neither exists yet — generated once at MAIN_ROOT, then linked into PROJECT_ROOT" {
  MAIN=$(mktemp -d)
  echo "FOO=bar" > "$MAIN/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.env" ]
  [ ! -L "$MAIN/.env" ]
  diff "$MAIN/.env.example" "$MAIN/.env"
  [ -L "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "$(cat "$MAIN/.env")" ]
  rm -rf "$MAIN"
}

@test "--main-root: neither exists and MAIN_ROOT has no .env.example — empty .env generated at MAIN_ROOT and linked" {
  MAIN=$(mktemp -d)

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.env" ]
  [ ! -L "$MAIN/.env" ]
  [ -L "$PROJECT/.env" ]
  rm -rf "$MAIN"
}

@test "--main-root equal to --project-root behaves exactly like not passing it" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "--main-root: an existing real PROJECT_ROOT .env still wins over everything, MAIN_ROOT included" {
  MAIN=$(mktemp -d)
  echo "SECRET=real" > "$MAIN/.env"
  echo "REAL=1" > "$PROJECT/.env"

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
  rm -rf "$MAIN"
}

@test "--main-root: a dangling MAIN_ROOT .env symlink is cleared before generating a real one" {
  MAIN=$(mktemp -d)
  ln -s "$MAIN/nonexistent-target" "$MAIN/.env"
  echo "FOO=bar" > "$MAIN/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.env" ]
  [ ! -L "$MAIN/.env" ]
  diff "$MAIN/.env.example" "$MAIN/.env"
  [ -L "$PROJECT/.env" ]
  rm -rf "$MAIN"
}

# ─── .env is always excluded from the git repo it lands in ─────────────────────────────
#
# A worker's own `git add -A` must never pick up a .env this script created or linked — a
# symlink into MAIN_ROOT committed into a branch is exactly what makes `merge-branches.sh`
# fail later with "untracked working tree files would be overwritten by merge" the moment
# MAIN_ROOT's own real .env differs in kind from what the branch wants to materialise there.

# ─── the discovered env override (.coding-crew/dev-commands.json's "env" field) ────────────
#
# discover-commands.sh / write-commands-cache.sh run once (bootstrap) and may cache a
# documented .env-bootstrap command this script would otherwise never see (it deliberately
# never reads CLAUDE.md itself). When that cache names one, it wins over the mechanical
# .env.example-or-empty convention below — mirroring ensure-deps.sh's own "install" override.

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

@test "--main-root: the discovered env command is read from MAIN_ROOT's cache and runs there, not PROJECT_ROOT's" {
  MAIN=$(mktemp -d)
  mkdir -p "$MAIN/.coding-crew"
  printf '{"env": "echo CUSTOM=1 > .env"}' > "$MAIN/.coding-crew/dev-commands.json"

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.env" ]
  [ ! -L "$MAIN/.env" ]
  [ "$(cat "$MAIN/.env")" = "CUSTOM=1" ]
  [ -L "$PROJECT/.env" ]
  rm -rf "$MAIN"
}

@test "--main-root: a PROJECT_ROOT-only cached env command is ignored — the override lives with MAIN_ROOT's discovery" {
  MAIN=$(mktemp -d)
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": "echo SHOULD_NOT_RUN=1 > .env"}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "FOO=bar" > "$MAIN/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.env" ]
  diff "$MAIN/.env.example" "$MAIN/.env"
  rm -rf "$MAIN"
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

@test "--main-root: linking a MAIN_ROOT .env into a worktree excludes .env in the shared git dir" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  git -C "$MAIN" commit -q --allow-empty -m init
  echo "SECRET=real" > "$MAIN/.env"
  rmdir "$PROJECT"
  git -C "$MAIN" worktree add -q --detach "$PROJECT"

  run bash "$SCRIPT" --project-root "$PROJECT" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  grep -qx '.env' "$MAIN/.git/info/exclude"
  rm -rf "$MAIN"
}

