#!/usr/bin/env bash
set -euo pipefail

# discover-commands.sh [--refresh] — prints the prompt asking a model for this repo's dev-loop
# commands (test, lint, typecheck, install, env, registry_auth, coverage, integration), listing
# file paths, not contents; with no candidate file, asks for the ecosystem's conventional
# test/lint/typecheck commands instead; prints "skipped" when every field asked about is cached.
# A cached field, even null, is never re-asked: a fresh guess must not overwrite a hand-edited
# answer. --refresh re-asks all eight. The prompt ends with the commands that save the answer
# (write-commands-cache.sh), so every skill that discovers the commands saves them the same way.

REFRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) REFRESH=1; shift ;;
    *) echo "discover-commands.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/commands-file.sh"
CACHE_FILE=$(commands_file "$ROOT")

# A key is "already discovered" once present with any value; JSON `null` means a model looked and
# found none. Other fields (install_mode, docker_service) share the file, so the file existing proves nothing.
CACHE_FIELDS=(test lint typecheck install env registry_auth coverage integration)

# Fixed order keeps the hash stable and is the priority handed to the model: docs, build files, manifests.
CANDIDATE_FILES=(
  "$ROOT/CLAUDE.md"
  "$ROOT/AGENTS.md"
  "$ROOT/Makefile"
  "$ROOT/README.md"
  "$ROOT/package.json"
  "$ROOT/pyproject.toml"
  "$ROOT/Cargo.toml"
  "$ROOT/go.mod"
  "$ROOT/Gemfile"
  "$ROOT/composer.json"
)

# _content_hash <file> — spots duplicates (a CLAUDE.md symlinked to AGENTS.md) so the prompt lists each once.
_content_hash() {
  cat "$1" | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'
}

FOUND_FILES=()
SEEN_HASHES=()
for f in "${CANDIDATE_FILES[@]}"; do
  [ -f "$f" ] || continue
  h=$(_content_hash "$f")
  dup=0
  if [ "${#SEEN_HASHES[@]}" -gt 0 ]; then
    for seen in "${SEEN_HASHES[@]}"; do
      if [ "$seen" = "$h" ]; then dup=1; break; fi
    done
  fi
  if [ "$dup" -eq 0 ]; then
    FOUND_FILES+=("$f")
    SEEN_HASHES+=("$h")
  fi
done

_in_ask() {
  local key="$1" f
  for f in "${ASK_FIELDS[@]}"; do
    [ "$f" = "$key" ] && return 0
  done
  return 1
}

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSWER="$ROOT/.discovered-commands.json"
# _print_save_commands — the prompt's closing lines: the commands that save the answer for ASK_FIELDS.
_print_save_commands() {
  cat <<'PROMPT'

On an interactive run, show the person your answer, one command per line, and take their
corrections before you save it. On a non-interactive run (a headless/-p invocation or a subagent),
save it without asking.

Save it by running these commands with your answer as the JSON:

PROMPT
  local key json_shape=""
  for key in "${CACHE_FIELDS[@]}"; do
    _in_ask "$key" || continue
    [ -n "$json_shape" ] && json_shape="$json_shape, "
    json_shape="$json_shape\"$key\": \"<command or null>\""
  done
  cat <<PROMPT
cat > $(printf '%q' "$ANSWER") <<'JSON'
{$json_shape}
JSON
(cd $(printf '%q' "$ROOT") && bash $(printf '%q' "$SELF_DIR/write-commands-cache.sh") --response-file .discovered-commands.json)
rm -f $(printf '%q' "$ANSWER")
--- end command discovery prompt ---
PROMPT
}

# No file names the commands: the checks still need test/lint/typecheck saved (null included), or
# run-checks.sh keeps answering DISCOVER, so ask for the ecosystem's conventional commands.
if [ "${#FOUND_FILES[@]}" -eq 0 ]; then
  if [ "$REFRESH" = "0" ] && [ -f "$CACHE_FILE" ] && commands_field_present "$CACHE_FILE" test; then
    echo "Command discovery: skipped (no CLAUDE.md, AGENTS.md, README.md, Makefile, or manifest found; already cached at $CACHE_FILE)"
    exit 0
  fi
  ASK_FIELDS=(test lint typecheck)
  cat <<'PROMPT'
Command discovery: no CLAUDE.md, AGENTS.md, README.md, Makefile, or known manifest found — ecosystem-convention fallback

--- command discovery prompt ---
No file in this repository documents its dev-loop commands. Look at the build files it does have
(pom.xml, build.gradle, *.csproj, mix.exs, …) and give the ecosystem's conventional local command
for each of test, lint (one that reports, never one that rewrites files) and typecheck — e.g.
`mvn test`, `./gradlew test`, `dotnet test`, `mix test`, `go test ./...`, `pytest`. Use null for
a category the ecosystem has no conventional command for, or that its tool is not set up for here.
PROMPT
  _print_save_commands
  exit 0
fi

# ASK_FIELDS — the fields this run asks about: every field absent from the cache, or all eight under --refresh.
ASK_FIELDS=()
for key in "${CACHE_FIELDS[@]}"; do
  if [ "$REFRESH" = "1" ] || [ ! -f "$CACHE_FILE" ] || ! commands_field_present "$CACHE_FILE" "$key"; then
    ASK_FIELDS+=("$key")
  fi
done

if [ "${#ASK_FIELDS[@]}" -eq 0 ]; then
  echo "Command discovery: skipped (already cached at $CACHE_FILE)"
  exit 0
fi

echo "Command discovery: ${#FOUND_FILES[@]} source file(s) found — building discovery prompt for ${#ASK_FIELDS[@]} of eight categories"
echo

cat <<'PROMPT'
--- command discovery prompt (do not run this on a cheap model tier — it is genuine reasoning) ---
You are working in this repository's own working directory and have normal file-read access
to it. Identify the command a developer runs **locally**, during normal iteration, for each
of the categories below only:

PROMPT

_in_ask test && cat <<'PROMPT'
- test (the bare command, e.g. `pnpm test`, never a `docker compose run …` wrapper: the checks
  run it inside the project's container themselves when the project is set up that way; any env
  it needs goes inside the command, e.g. `CI=true pnpm test` when `pnpm-lock.yaml` exists)
PROMPT
_in_ask lint && cat <<'PROMPT'
- lint (the documented one; one that fixes what it finds, such as `eslint --fix` or a
  `make lint` that runs a formatter, is fine: its fixes are committed once they settle)
PROMPT
_in_ask typecheck && cat <<'PROMPT'
- typecheck (a static/type-checking pass — not the test suite)
PROMPT
_in_ask install && cat <<'PROMPT'
- install (installing project dependencies before running the other three — not building,
  compiling, migrating, or seeding data). Only report one if the source explicitly documents
  it; a repo with no stated install command already falls back to its own lockfile/manifest
  convention (npm ci, bundle install, …) elsewhere, so guessing one here would only override
  that convention with a worse guess.
PROMPT
_in_ask env && cat <<'PROMPT'
- env (the command that creates or bootstraps a working local `.env` file — e.g. `cp
  .env.example .env`, `make env`, a documented setup script — not setting one variable inline,
  not CI/deploy secrets). Only report one if the source explicitly documents it; a repo with
  no stated env command already falls back to copying `.env.example` (or creating an empty
  file) elsewhere, so guessing one here would only override that convention with a worse
  guess.
PROMPT
_in_ask registry_auth && cat <<'PROMPT'
- registry_auth (the build target — if any — whose recipe generates package-manager
  credential config files such as `.npmrc`, `pip.conf`, or `.cargo/credentials.toml` from a
  template or env vars — not the `.env` bootstrap itself, that's env above). Report the full
  command that runs it (e.g. `make _registry`), not just the bare target name — same shape as
  install and env above. Only report one if such a target explicitly exists; a repo with none
  already falls back to expanding any `*.tpl` files with no generated counterpart elsewhere, so
  guessing here would only override that convention with a worse guess.
PROMPT
_in_ask coverage && cat <<'PROMPT'
- coverage (the local command that produces a test coverage report — e.g. `npm test --
  --coverage`, `pytest --cov`, `go test -cover ./...` — not a coverage upload or
  reporting-service step). Only report one if the source explicitly documents it, or an
  unambiguous build-file target clearly serves this purpose; a repo with no discoverable
  coverage command has no fallback convention to guess from, so guessing one here would only
  override the honest answer "no coverage tooling configured" with a worse guess.
PROMPT
_in_ask integration && cat <<'PROMPT'
- integration (the command, if any, that runs a *real* dependency-backed integration test tier
  — e.g. `make test-integration`, something gated behind a `startLocalstack`-style setup — as
  distinct from a tier that only mocks the dependency away). Only report one if explicitly
  discoverable; a repo with no such tier already falls back to treating every test as running
  against a mocked boundary elsewhere, so guessing one here would only override that convention
  with a worse guess.
PROMPT

cat <<'PROMPT'

Read these files yourself, in the order listed below — that order is priority order, most
authoritative first (project docs, then build files, then package manifests):
PROMPT

for f in "${FOUND_FILES[@]}"; do
  printf '  - %s\n' "${f#"$ROOT"/}"
done

cat <<'PROMPT'

Stop reading as soon as you have a confident answer — including a confident "no local command
exists" — for every category listed above; you do not need to open every file above if an
earlier one already answers them all.
PROMPT

if _in_ask install && _in_ask env && _in_ask registry_auth; then
  cat <<'PROMPT'
The three exceptions are install, env, and registry_auth:
you MUST open any Makefile in the list above before concluding any of the three is null —
see the rule below. This overrides the "stop once confident" instruction; do not skip it just
because the docs already answered the other three, and do not treat a confident-sounding
silence in the docs as answering install, env, or registry_auth on its own.

Rules:
- install and env are the categories prose docs are least likely to mention — each is far more
  often only an explicit target in a Makefile (install/deps/bootstrap, or env/setup) than a
  sentence in the docs listed above. registry_auth is stricter still: it is *only* ever a
  Makefile target, never something prose docs state. If a Makefile appears in the list above,
  you MUST open it and check it for a matching target before answering null for install, null
  for env, or null for registry_auth — this is a required step, not a suggestion, even if
  the docs already answered test/lint/typecheck confidently. You may only answer null for
  install, null for env, or null for registry_auth once you have either (a) opened every
  Makefile in the list and found no matching target, or (b) confirmed no Makefile appears in
  the list above at all. Silence in the docs alone never justifies null for these three
  categories.
PROMPT
elif _in_ask install || _in_ask env || _in_ask registry_auth; then
  NAMES=""
  _in_ask install && NAMES="${NAMES:+$NAMES, }install"
  _in_ask env && NAMES="${NAMES:+$NAMES, }env"
  _in_ask registry_auth && NAMES="${NAMES:+$NAMES, }registry_auth"
  cat <<PROMPT
The exception is $NAMES: you MUST open any Makefile in the list above before concluding it is
null — this overrides the "stop once confident" instruction; do not treat a confident-sounding
silence in the docs as answering $NAMES on its own. You may only answer null for it once you
have either (a) opened every Makefile in the list and found no matching target, or (b)
confirmed no Makefile appears in the list above at all.

Rules:
PROMPT
else
  cat <<'PROMPT'

Rules:
PROMPT
fi

cat <<'PROMPT'
- Only local dev-loop commands. Ignore build, deploy, publish, and infra-provisioning steps
  (Docker image builds, CDK/Terraform/CloudFormation, docs bundling/rendering, release/publish
  workflows) even if they appear in the same file as a test/lint/typecheck/install command.
- Ignore anything the source explicitly marks as CI-only, manual-only, or "not gated by CI",
  unless no other candidate exists for that category.
- Where the source recommends against a shortcut (calls it broken, misleading, or says
  "don't use it"), use the alternative it recommends instead of the discouraged shortcut.
- If a category has no discoverable local command, use null for it — do not guess one.
- When any of the categories above resolves to a Makefile target, report the target invocation
  itself (e.g. "make test", "make deps", "make env") — never a command you believe is equivalent
  to what the target's recipe does underneath. A target's recipe can hide an existence guard
  (won't overwrite a file that's already there), a prerequisite chain, or an environment
  conditional (CI vs local) that a paraphrased "equivalent" command silently drops. This applies
  even if the recipe's final line is a single simple command — report the target invocation, not
  that line. This is not limited to install/env/registry_auth: a "test" or "lint" target is
  eval'd the same way downstream and loses the same guards if paraphrased.
PROMPT

# A manifest whose install puts tools in a project-local directory off PATH (a virtualenv,
# vendor/bin) makes a bare `pytest` or `phpunit` fail as "command not found". One line per
# ecosystem present; uv before poetry, the order host-install.sh picks them in.
_runner_rule() { # <manifest> <tools> <where> <runner> <example: runner + tool> <tool>
  cat <<PROMPT
- This project has a $1: its $2 are installed into $3, which is not on PATH. Report each such
  tool's command through \`$4\` (e.g. \`$5\`, not \`$6\`), unless the source names a command
  that already runs it that way (a Makefile target, a package-manager script).
PROMPT
}
if [ -f "$ROOT/uv.lock" ]; then
  _runner_rule uv.lock "Python tools" "a project virtualenv" "uv run" "uv run pytest" pytest
elif [ -f "$ROOT/poetry.lock" ]; then
  _runner_rule poetry.lock "Python tools" "a project virtualenv" "poetry run" "poetry run pytest" pytest
fi
if [ -f "$ROOT/composer.json" ]; then
  _runner_rule composer.json "PHP tools" "vendor/bin" "vendor/bin/" "vendor/bin/phpunit" phpunit
fi

_print_save_commands
