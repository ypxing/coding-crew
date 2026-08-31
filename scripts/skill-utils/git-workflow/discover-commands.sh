#!/usr/bin/env bash
set -euo pipefail

# Command discovery — mechanical gate for crew-afk (prompt-builder half)
#
# Finds the *local dev-loop* command for test/lint/typecheck/install/env/credential_target once
# per sprint, before
# any worktree exists, by asking a model to read whatever of CLAUDE.md/AGENTS.md/Makefile/manifest
# files this repo actually has — the same reference chain solve-issue's verification.md names,
# but read by a model instead of pattern-matched by this script. Real repos document these
# commands in prose, tables, and bullet lists a regex has no reliable way to parse (a table
# with a "don't use this shortcut, it's broken" note in a column is exactly the shape that
# broke the pattern-matched approach this replaces).
#
# This script only ever decides whether a model call is needed and, if so, assembles the
# prompt for it — mirroring coverage-validation.sh's shape exactly, down to the "skipped" /
# not-skipped stdout contract loop.mjs already knows how to read (the whole of stdout becomes
# the prompt, informational preamble included, exactly as it does there). It never calls a
# model itself, and it never writes a result anywhere; a sibling script owns turning the
# model's response into .coding-crew/dev-commands.json.
#
# The prompt lists candidate *paths*, not their contents. dispatchPlain() hands the model the
# same read/bash/edit/write toolset an interactive session gets (see dispatch.mjs), so the
# model can open each file itself instead of having every candidate — a 950-line CLAUDE.md
# included — pasted whole into a single CLI argv string. Content-in-prompt used to be how
# this was built; it spent tokens on files the model often never needed (a Makefile no one
# asked about, once CLAUDE.md alone answered all six categories), and had no ceiling as a
# repo's own docs grew. Paths are listed in the same fixed priority order as CANDIDATE_FILES
# below (docs before build files before manifests), and the model is told to stop reading
# once it has an answer for all six categories, so a repo that documents everything in
# CLAUDE.md never pays to have its Makefile and package.json read too.
#
# install is the fourth category, added so ensure-deps.sh (which deliberately never reads
# CLAUDE.md itself — see its own header comment) can use a documented override instead of its
# mechanical Makefile-target/lockfile heuristic. It is optional: a null install here is not a
# failure, it means ensure-deps.sh's existing convention-based detection already covers this
# repo and there is nothing to override.
#
# env is the fifth category, added so ensure-env.sh (same reason — it never reads CLAUDE.md
# itself either) can use a documented .env-bootstrap override instead of its mechanical
# .env.example-or-empty convention. Also optional, for the same reason: a null env means that
# convention already covers this repo.
#
# credential_target is the sixth category: the command (if any) that runs the Makefile target
# whose recipe generates package-manager credential config files (.npmrc, pip.conf,
# .cargo/credentials.toml, …) from a template or env vars — not the .env bootstrap itself
# (that's env, above). Like install/env, this is a full runnable command (e.g. "make _registry"),
# not a bare target name — ensure-env.sh eval's it directly, the same way it evals a cached env
# command, instead of reconstructing a `make` invocation itself from a name alone. Consumed by
# ensure-deps.sh, which forwards a cached value to docker-install.sh's --credential-target flag
# instead of dep-install's docker-install.md scanning Makefile comments for it on every run.
# Also optional: a null here means no such target exists, so ensure-env.sh's own template-only
# fallback (envsubst on any *.tpl files) already covers this repo.
#
# Skips (mechanically, no model call, no tokens) when either:
#   1. none of the known source files exist — verify-worktree.sh's own ecosystem-convention
#      fallback already covers this case for free, so there is nothing to ask a model
#   2. the committed .coding-crew/dev-commands.json already exists — bootstrap-once, not a
#      recurring staleness check: the file is committed and human-editable, so it is trusted
#      as-is, indefinitely, until a human clears it or explicitly asks for --refresh
#
# Invocation: bash "<skill-dir>/scripts/discover-commands.sh" [--refresh]
# Env: CREW_COMMANDS_REFRESH=1 has the same effect as --refresh.

REFRESH="${CREW_COMMANDS_REFRESH:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh) REFRESH=1; shift ;;
    *) echo "discover-commands.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# MAIN_ROOT resolution — must land on the *shared* main checkout even if this ever runs from
# inside a linked worktree (normally it does not: commands.mjs always invokes it with
# cwd=mainRoot, before any worktree exists — this is defensive symmetry with
# write-commands-cache.sh, which solve-issue's own DISCOVER fallback can invoke from a
# worker's worktree cwd). Prefer the $MAIN_ROOT env var the orchestrator/dispatcher exports,
# then _main_root_of's --git-common-dir trick (mirrors verify-worktree.sh's own helper of the
# same name), which resolves the main worktree's root from any linked worktree without an env
# var. `git rev-parse --show-toplevel` alone returns the *current* worktree's own root, which
# is wrong from inside a linked worktree.
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

# Fixed, deterministic order — keeps the hash (and the prompt's file order) stable across
# runs regardless of filesystem iteration order. Not tied to any one repo's stack: covers the
# doc conventions (CLAUDE.md/AGENTS.md/Makefile) plus one manifest per common ecosystem. This
# is also the priority order handed to the model: docs first (most likely to state the
# command in prose), build files next, manifests last (often just a script name to infer).
CANDIDATE_FILES=(
  "$MAIN_ROOT/CLAUDE.md"
  "$MAIN_ROOT/AGENTS.md"
  "$MAIN_ROOT/Makefile"
  "$MAIN_ROOT/package.json"
  "$MAIN_ROOT/pyproject.toml"
  "$MAIN_ROOT/Cargo.toml"
  "$MAIN_ROOT/go.mod"
  "$MAIN_ROOT/Gemfile"
  "$MAIN_ROOT/composer.json"
)

# _content_hash <file> — one file's own content, independent of its path. Used only to spot
# duplicates (a CLAUDE.md that is a symlink to AGENTS.md, or two files that happen to hold
# identical content) before either file is added to the prompt: real repos symlink one to the
# other for editor convenience, and quoting the same text twice would cost tokens for zero
# extra information without changing what the model can answer.
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
  echo "Command discovery: skipped (no CLAUDE.md, AGENTS.md, Makefile, or manifest found — ecosystem-convention fallback applies)"
  exit 0
fi

# Bootstrap-once, not a recurring staleness re-check: once the committed cache file exists,
# it is trusted as-is until a human clears it or explicitly passes --refresh.
if [ "$REFRESH" != "1" ] && [ -f "$CACHE_FILE" ]; then
  echo "Command discovery: skipped (already cached at .coding-crew/dev-commands.json)"
  exit 0
fi

echo "Command discovery: ${#FOUND_FILES[@]} source file(s) found — building discovery prompt"
echo

cat <<'PROMPT'
--- command discovery prompt (do not run this on a cheap model tier — it is genuine reasoning) ---
You are working in this repository's own working directory and have normal file-read access
to it. Identify the command a developer runs **locally**, during normal iteration, for each
of these six categories only:

- test
- lint
- typecheck (a static/type-checking pass — not the test suite)
- install (installing project dependencies before running the other three — not building,
  compiling, migrating, or seeding data). Only report one if the source explicitly documents
  it; a repo with no stated install command already falls back to its own lockfile/manifest
  convention (npm ci, bundle install, …) elsewhere, so guessing one here would only override
  that convention with a worse guess.
- env (the command that creates or bootstraps a working local `.env` file — e.g. `cp
  .env.example .env`, `make env`, a documented setup script — not setting one variable inline,
  not CI/deploy secrets). Only report one if the source explicitly documents it; a repo with
  no stated env command already falls back to copying `.env.example` (or creating an empty
  file) elsewhere, so guessing one here would only override that convention with a worse
  guess.
- credential_target (the build target — if any — whose recipe generates package-manager
  credential config files such as `.npmrc`, `pip.conf`, or `.cargo/credentials.toml` from a
  template or env vars — not the `.env` bootstrap itself, that's env above). Report the full
  command that runs it (e.g. `make _registry`), not just the bare target name — same shape as
  install and env above. Only report one if such a target explicitly exists; a repo with none
  already falls back to expanding any `*.tpl` files with no generated counterpart elsewhere, so
  guessing here would only override that convention with a worse guess.

Read these files yourself, in the order listed below — that order is priority order, most
authoritative first (project docs, then build files, then package manifests):
PROMPT

for f in "${FOUND_FILES[@]}"; do
  printf '  - %s\n' "${f#"$MAIN_ROOT"/}"
done

cat <<'PROMPT'

Stop reading as soon as you have a confident answer — including a confident "no local command
exists" — for all six categories; you do not need to open every file above if an earlier one
already answers all six. The three exceptions are install, env, and credential_target:
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
- Only local dev-loop commands. Ignore build, deploy, publish, and infra-provisioning steps
  (Docker image builds, CDK/Terraform/CloudFormation, docs bundling/rendering, release/publish
  workflows) even if they appear in the same file as a test/lint/typecheck/install command.
- Ignore anything the source explicitly marks as CI-only, manual-only, or "not gated by CI",
  unless no other candidate exists for that category.
- Where the source recommends against a shortcut (calls it broken, misleading, or says
  "don't use it"), use the alternative it recommends instead of the discouraged shortcut.
- If a category has no discoverable local command, use null for it — do not guess one.

Respond with **only** this JSON shape, no other prose:
{"test": "<command or null>", "lint": "<command or null>", "typecheck": "<command or null>", "install": "<command or null>", "env": "<command or null>", "credential_target": "<command or null, e.g. \"make _registry\">"}
--- end command discovery prompt ---
PROMPT
