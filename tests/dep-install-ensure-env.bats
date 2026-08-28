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

# ─── the discovered env override (.scratch/commands.json's "env" field) ────────────────────
#
# discover-commands.sh / write-commands-cache.sh run once per sprint and may cache a
# documented .env-bootstrap command this script would otherwise never see (it deliberately
# never reads CLAUDE.md itself). When that cache names one, it wins over the mechanical
# .env.example-or-empty convention below — mirroring ensure-deps.sh's own "install" override.

@test "a documented env command in .scratch/commands.json is used instead of the .env.example convention" {
  mkdir -p "$PROJECT/.scratch"
  printf '{"sourceHash": "x", "env": "echo CUSTOM=1 > .env"}' > "$PROJECT/.scratch/commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "CUSTOM=1" ]
  [[ "$output" == *"discovered"* ]]
}

@test "a null env in commands.json falls back to the .env.example convention unchanged" {
  mkdir -p "$PROJECT/.scratch"
  printf '{"sourceHash": "x", "env": null}' > "$PROJECT/.scratch/commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "no commands.json at all falls back to the .env.example convention unchanged" {
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "a failing discovered env command still leaves a real .env behind via the mechanical fallback" {
  mkdir -p "$PROJECT/.scratch"
  printf '{"sourceHash": "x", "env": "echo custom env boom >&2; exit 5"}' > "$PROJECT/.scratch/commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "a discovered env command that exits 0 but never creates .env falls back to the mechanical convention" {
  mkdir -p "$PROJECT/.scratch"
  printf '{"sourceHash": "x", "env": "true"}' > "$PROJECT/.scratch/commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "an existing real .env still wins over a discovered env command" {
  mkdir -p "$PROJECT/.scratch"
  printf '{"sourceHash": "x", "env": "echo SHOULD_NOT_RUN=1 > .env"}' > "$PROJECT/.scratch/commands.json"
  echo "REAL=1" > "$PROJECT/.env"

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}

@test "--main-root: the discovered env command is read from MAIN_ROOT's cache and runs there, not PROJECT_ROOT's" {
  MAIN=$(mktemp -d)
  mkdir -p "$MAIN/.scratch"
  printf '{"sourceHash": "x", "env": "echo CUSTOM=1 > .env"}' > "$MAIN/.scratch/commands.json"

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
  mkdir -p "$PROJECT/.scratch"
  printf '{"sourceHash": "x", "env": "echo SHOULD_NOT_RUN=1 > .env"}' > "$PROJECT/.scratch/commands.json"
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
