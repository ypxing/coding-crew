#!/usr/bin/env bats

# ensure-env.sh — steps 0b-c of docker-install.md. Pins the "always exits 0, .env exists
# after it runs" contract.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks/ensure-env.sh"

setup() {
  PROJECT=$(mktemp -d)
  export PROJECT
}

teardown() {
  rm -rf "$PROJECT"
}

# _cache <json> — the checkout's dev commands file (the tracked path: $PROJECT is no git checkout).
_cache() {
  mkdir -p "$PROJECT/.coding-crew"
  printf '%s\n' "$1" > "$PROJECT/.coding-crew/dev-commands.json"
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

@test "a null env never runs a Makefile env target: .env comes from .env.example" {
  mkdir -p "$PROJECT/.coding-crew"
  printf '{"env": null}' > "$PROJECT/.coding-crew/dev-commands.json"
  echo "FOO=bar" > "$PROJECT/.env.example"
  printf 'env:\n\techo MAKE_ENV=1 > .env\n' > "$PROJECT/Makefile"

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

# ─── registry_auth: the dev commands file's full command (e.g. "make _registry"), evaled directly,
# guarded against docker-in-docker nesting the same way docker-install.sh's install command is ─────

@test "the dev commands file's registry_auth runs after .env exists and generates the credential file" {
  cat > "$PROJECT/Makefile" <<'MK'
.npmrc:
	echo "TOKEN=x" > .npmrc
MK

  _cache '{"registry_auth": "test -f .env && make .npmrc"}'
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ -f "$PROJECT/.npmrc" ]
  [[ "$output" == *"ran discovered registry_auth"* ]]
}

@test "a registry_auth command that already invokes docker is skipped, never eval'd" {
  _cache '{"registry_auth": "docker compose run --rm app make _registry"}'
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already invokes docker"* ]]
  [ ! -f "$PROJECT/.npmrc" ]
}

@test "a registry_auth bare 'make <target>' whose recipe invokes docker is also skipped" {
  cat > "$PROJECT/Makefile" <<'MK'
_registry:
	docker compose run --rm app ./gen-creds.sh
MK

  _cache '{"registry_auth": "make _registry"}'
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already invokes docker"* ]]
}

@test "a failing registry_auth command is reported, not fatal" {
  _cache '{"registry_auth": "exit 5"}'
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed, falling back to template expansion"* ]]
}
