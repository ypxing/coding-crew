#!/usr/bin/env bash
set -euo pipefail

# discover-commands.sh [--refresh] — prints the prompt asking a model for this repo's dev-loop
# commands (test, lint, typecheck, install, env, credential_target, coverage, integration), listing
# file paths, not contents; prints "skipped" when no candidate exists or every field is cached.
# A cached field, even null, is never re-asked: a fresh guess must not overwrite a hand-edited
# answer. --refresh (or CREW_COMMANDS_REFRESH=1) re-asks all eight.

REFRESH="${CREW_COMMANDS_REFRESH:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) REFRESH=1; shift ;;
    *) echo "discover-commands.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Must land on the shared main checkout even from a linked worktree, where
# `git rev-parse --show-toplevel` returns the worktree's own root.
_main_root_of() {
  local dir="$1" common
  common=$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) : ;;
    *) common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")" ;;
  esac
  dirname "$common"
}

MAIN_ROOT="${MAIN_ROOT:-}"
if [ -z "$MAIN_ROOT" ]; then
  MAIN_ROOT=$(_main_root_of "$(pwd)") || MAIN_ROOT=$(git rev-parse --show-toplevel)
fi
CACHE_FILE="$MAIN_ROOT/.coding-crew/dev-commands.json"

# A key is "already discovered" once present with any value; JSON `null` means a model looked and
# found none. ensure-deps.sh writes its own fields to the same file, so the file existing proves nothing.
CACHE_FIELDS=(test lint typecheck install env credential_target coverage integration)

# _cache_field_present <file> <key> — same regex as write-commands-cache.sh's _extract_field.
_cache_field_present() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  grep -q "\"$key\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" "$file"
}

# Fixed order keeps the hash stable and is the priority handed to the model: docs, build files, manifests.
CANDIDATE_FILES=(
  "$MAIN_ROOT/CLAUDE.md"
  "$MAIN_ROOT/AGENTS.md"
  "$MAIN_ROOT/Makefile"
  "$MAIN_ROOT/README.md"
  "$MAIN_ROOT/package.json"
  "$MAIN_ROOT/pyproject.toml"
  "$MAIN_ROOT/Cargo.toml"
  "$MAIN_ROOT/go.mod"
  "$MAIN_ROOT/Gemfile"
  "$MAIN_ROOT/composer.json"
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

if [ "${#FOUND_FILES[@]}" -eq 0 ]; then
  echo "Command discovery: skipped (no CLAUDE.md, AGENTS.md, README.md, Makefile, or manifest found — ecosystem-convention fallback applies)"
  exit 0
fi

# ASK_FIELDS — the fields this run asks about: every field absent from the cache, or all eight under --refresh.
ASK_FIELDS=()
for key in "${CACHE_FIELDS[@]}"; do
  if [ "$REFRESH" = "1" ] || [ ! -f "$CACHE_FILE" ] || ! _cache_field_present "$CACHE_FILE" "$key"; then
    ASK_FIELDS+=("$key")
  fi
done

if [ "${#ASK_FIELDS[@]}" -eq 0 ]; then
  echo "Command discovery: skipped (already cached at .coding-crew/dev-commands.json)"
  exit 0
fi

echo "Command discovery: ${#FOUND_FILES[@]} source file(s) found — building discovery prompt for ${#ASK_FIELDS[@]} of eight categories"
echo

_in_ask() {
  local key="$1" f
  for f in "${ASK_FIELDS[@]}"; do
    [ "$f" = "$key" ] && return 0
  done
  return 1
}

cat <<'PROMPT'
--- command discovery prompt (do not run this on a cheap model tier — it is genuine reasoning) ---
You are working in this repository's own working directory and have normal file-read access
to it. Identify the command a developer runs **locally**, during normal iteration, for each
of the categories below only:

PROMPT

_in_ask test && cat <<'PROMPT'
- test
PROMPT
_in_ask lint && cat <<'PROMPT'
- lint (one that reports, not one that rewrites files: every check fails when it leaves the
  tree modified, so when the documented lint auto-fixes and the source also documents a
  non-fixing form — a `lint:check` script, a `make lint-check` target — report that one)
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
_in_ask credential_target && cat <<'PROMPT'
- credential_target (the build target — if any — whose recipe generates package-manager
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
  printf '  - %s\n' "${f#"$MAIN_ROOT"/}"
done

cat <<'PROMPT'

Stop reading as soon as you have a confident answer — including a confident "no local command
exists" — for every category listed above; you do not need to open every file above if an
earlier one already answers them all.
PROMPT

if _in_ask install && _in_ask env && _in_ask credential_target; then
  cat <<'PROMPT'
The three exceptions are install, env, and credential_target:
you MUST open any Makefile in the list above before concluding any of the three is null —
see the rule below. This overrides the "stop once confident" instruction; do not skip it just
because the docs already answered the other three, and do not treat a confident-sounding
silence in the docs as answering install, env, or credential_target on its own.

Rules:
- install and env are the categories prose docs are least likely to mention — each is far more
  often only an explicit target in a Makefile (install/deps/bootstrap, or env/setup) than a
  sentence in the docs listed above. credential_target is stricter still: it is *only* ever a
  Makefile target, never something prose docs state. If a Makefile appears in the list above,
  you MUST open it and check it for a matching target before answering null for install, null
  for env, or null for credential_target — this is a required step, not a suggestion, even if
  the docs already answered test/lint/typecheck confidently. You may only answer null for
  install, null for env, or null for credential_target once you have either (a) opened every
  Makefile in the list and found no matching target, or (b) confirmed no Makefile appears in
  the list above at all. Silence in the docs alone never justifies null for these three
  categories.
PROMPT
elif _in_ask install || _in_ask env || _in_ask credential_target; then
  NAMES=""
  _in_ask install && NAMES="${NAMES:+$NAMES, }install"
  _in_ask env && NAMES="${NAMES:+$NAMES, }env"
  _in_ask credential_target && NAMES="${NAMES:+$NAMES, }credential_target"
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
  that line. This is not limited to install/env/credential_target: a "test" or "lint" target is
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
if [ -f "$MAIN_ROOT/uv.lock" ]; then
  _runner_rule uv.lock "Python tools" "a project virtualenv" "uv run" "uv run pytest" pytest
elif [ -f "$MAIN_ROOT/poetry.lock" ]; then
  _runner_rule poetry.lock "Python tools" "a project virtualenv" "poetry run" "poetry run pytest" pytest
fi
if [ -f "$MAIN_ROOT/composer.json" ]; then
  _runner_rule composer.json "PHP tools" "vendor/bin" "vendor/bin/" "vendor/bin/phpunit" phpunit
fi

cat <<'PROMPT'

Respond with **only** this JSON shape, no other prose:
PROMPT

JSON_SHAPE=""
for key in "${CACHE_FIELDS[@]}"; do
  _in_ask "$key" || continue
  [ -n "$JSON_SHAPE" ] && JSON_SHAPE="$JSON_SHAPE, "
  if [ "$key" = "credential_target" ]; then
    JSON_SHAPE="${JSON_SHAPE}\"credential_target\": "'"<command or null, e.g. \"make _registry\">"'
  else
    JSON_SHAPE="$JSON_SHAPE\"$key\": \"<command or null>\""
  fi
done
printf '{%s}\n' "$JSON_SHAPE"
echo "--- end command discovery prompt ---"
