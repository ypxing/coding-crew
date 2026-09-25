#!/usr/bin/env bash
set -uo pipefail

# verify-worktree.sh — run project checks in a worktree directory
#
# Usage: verify-worktree.sh --dir <worktree-path> [--extra <category>[,<category>...]] [--stem <n>-<slug>]
#
# --extra names further dev-commands.json categories (e.g. coverage,integration) to run after
# the three base checks — the ones a worker says this issue's acceptance criteria call for.
# Names only, never commands: each resolves through the same cache lookup as the base three,
# so the cache stays the allow-list of what this gate will execute. A requested category is
# required — no cached command for it is fatal, not a silent not_run — and its full output is
# always persisted, with its path printed as `<LABEL>: log: <path>`, so a reviewer can read a
# figure (a coverage percentage) that pass/fail alone cannot carry.
#
# In a crew worktree the run's evidence is written to the sprint's dispatch directory, next to
# the issue's other dispatch files and named with the same `<n>-<slug>` stem (--stem; the bare
# slug when absent): `<stem>.verify.json` — branch, commit, verdict, and per check its
# category, command, result, exit code and log — plus `<stem>.verify-<check>.log`, every check's
# full output. The JSON is also the merge receipt (see receipts.sh): merge-branches.sh accepts
# only a `pass` verdict recorded for the branch's current tip. It outlives the worktree, so what
# the gate did can be read after the fact. Outside a crew worktree nothing is recorded, and full
# output is kept under <worktree>/.scratch/ only when it was capped.
#
# Discovers check commands using this reference chain:
#   0. .coding-crew/dev-commands.json at MAIN_ROOT (see discover-commands.sh / write-commands-cache.sh)
#      — a model's one-time reading of CLAUDE.md/AGENTS.md/Makefile/manifest, done once
#      (bootstrap) before any worktree exists, not re-derived by this gate. A category the cache
#      resolves to `null` is trusted as-is (no local command exists) and is not retried
#      against steps 1-3 below — the whole point of the cache is that a model already looked.
#   1. CLAUDE.md at the worktree root (explicit Run: commands under Tests section)
#   2. Makefile targets (test, lint, typecheck)
#   3. Ecosystem conventions (bats, npm test, pytest, cargo test, go test, etc.)
# Steps 1-3 only ever run when there is no usable cache at all (absent, or unparseable) —
# the fallback every repo already had before the cache existed.
#
# A check category with no discoverable command is reported explicitly as
# not_run — never silently treated as passing.
#
# A failing run records a `fail` verdict over any earlier pass, so a branch that once
# passed cannot merge on stale evidence.
#
# Exit code: 0 if all discovered checks pass, non-zero otherwise.

WORKTREE_DIR=""
EXTRA_CHECKS=""
STEM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      # Guard before reading $2 — under `set -u` a bare `--dir` would otherwise
      # abort with "$2: unbound variable" instead of the usage message.
      if [ $# -lt 2 ]; then
        echo "ERROR: --dir requires a value" >&2
        echo "Usage: $0 --dir <worktree-path>" >&2
        exit 1
      fi
      WORKTREE_DIR="$2"
      shift 2
      ;;
    --extra)
      if [ $# -lt 2 ]; then
        echo "ERROR: --extra requires a value" >&2
        exit 1
      fi
      EXTRA_CHECKS="$2"
      shift 2
      ;;
    --stem)
      if [ $# -lt 2 ]; then
        echo "ERROR: --stem requires a value" >&2
        exit 1
      fi
      STEM="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 --dir <worktree-path>" >&2
      exit 1
      ;;
  esac
done

if [ -z "$WORKTREE_DIR" ]; then
  echo "ERROR: --dir <worktree-path> is required" >&2
  exit 1
fi

if [ ! -d "$WORKTREE_DIR" ]; then
  echo "ERROR: directory does not exist: $WORKTREE_DIR" >&2
  exit 1
fi

# Resolve to the physical path once: a symlinked tmp dir (macOS's /var -> /private/var)
# would otherwise make the compose-file path built here disagree, string-wise, with the
# one _main_root_of resolves via `pwd -P` for MAIN_ROOT below — same file, different
# strings, and the docker-mode presence checks below would never line up.
WORKTREE_DIR="$(cd "$WORKTREE_DIR" && pwd -P)"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── docker-mode verification ─────────────────────────────────────────────────
#
# dep-install's own docker-install.md tells a worker "every subsequent docker compose
# command must pass both -f flags — including test, lint and type-check runs", because
# gen-override.sh mounts a *named volume* over the ecosystem's dependency directory
# (node_modules, .venv, …) at a container-side subpath — not a host bind-mount. Content
# written there by `yarn install` (via ensure-deps.sh's docker path) never exists on the
# host filesystem at all, in the worktree or in MAIN_ROOT. A worker gets that instruction
# from the skill; this gate cannot read a skill, so until now it ran every discovered
# command directly on the host — looking at a worktree whose node_modules never existed
# outside the container, and failing every check that needed it.
#
# Every signal below must resolve or this silently falls back to the existing host path —
# a gate must never stall a whole sprint because docker introspection failed.

# _main_root_of <dir> — the main worktree's root from any linked worktree. Mirrors
# receipts.sh's helper: --git-common-dir points at the *shared* .git directory (the main
# worktree's), not the per-worktree one, which is what makes this work from inside one.
_main_root_of() {
  local dir="$1" common
  # --path-format=absolute: without it, plain `--git-common-dir` can come back cwd-relative.
  # It still isn't enough on its own — git's own idea of "absolute" on Windows is a bare
  # drive-letter path like "C:/Users/...", which doesn't start with "/", so the *)-branch
  # below needs its own drive-letter case or it wrongly treats that as relative and mangles it.
  common=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*|[A-Za-z]:*) : ;;
    *) common="$dir/$common" ;;
  esac
  # Re-canonicalize through this shell's own `pwd -P` even though $common is already
  # absolute: git's drive-letter form ("C:/Users/...") is a different string than what
  # `pwd -P` prints for the same directory in this MSYS/git-bash shell ("/c/Users/..."),
  # and callers compare this return value against other paths this script resolves with
  # `pwd -P` (WORKTREE_DIR above) — leaving it in git's own form breaks that string equality
  # on Windows even though both name the same directory.
  common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")"
  dirname "$common"
}

# _vw_find_dep_scripts <main-root> — the same candidate order ensure-deps.sh uses, so a
# repo's dep-install scripts are found the same way regardless of which script asks.
_vw_find_dep_scripts() {
  local main_root="$1"
  if [ -n "${CREW_DEP_INSTALL_SCRIPTS:-}" ]; then
    [ -f "$CREW_DEP_INSTALL_SCRIPTS/gen-override.sh" ] && printf '%s' "$CREW_DEP_INSTALL_SCRIPTS"
    return 0
  fi
  local root candidate
  for root in "$main_root" "$(cd "$SELF_DIR/../../.." && pwd -P)" "$(cd "$SELF_DIR/../.." && pwd -P)"; do
    [ -n "$root" ] || continue
    for candidate in \
      "$root/.coding-crew/dep-install/scripts" \
      "$root/.claude/skills/dep-install/scripts" \
      "$root/.pi/skills/dep-install/scripts" \
      "$root/.agents/skills/dep-install/scripts" \
      "$root/.github/skills/dep-install/scripts" \
      "$root/skills/dep-install/scripts"; do
      if [ -f "$candidate/gen-override.sh" ]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  done
}

DOCKER_MODE=0
DOCKER_SERVICE=""
DOCKER_CONTAINER_SRC=""
DOCKER_COMPOSE_FILE=""
DOCKER_OVERRIDE_FILE=""
DEP_SCRIPTS_DIR=""
# This worktree's own GIT_DIR/GIT_COMMON_DIR/hooksPath redirect — resolved fresh per
# invocation via gen-override.sh's --query git-env, never baked into the shared override
# file (see gen-override.sh's "Git metadata mount" header comment for why: that file is
# shared across every worktree, but GIT_DIR is worktree-specific). Kept in two forms:
# DOCKER_GIT_ENV_ARGS as `-e KEY=VALUE` flags for a `docker compose run` this script calls
# directly, and DOCKER_GIT_ENV_LINES as bare `KEY=VALUE` for `env` to export ahead of a
# docker-nesting command this script instead runs on the host (see gen-override.sh's
# "Nested docker calls" header comment) — that command's own inner `docker compose run`
# only picks the values up via the shared override's bare passthrough entries if they are
# already in its caller's process env, which no `-e` flag reaches.
DOCKER_GIT_ENV_ARGS=()
DOCKER_GIT_ENV_LINES=()

# _detect_docker_mode — populates the DOCKER_* globals when this worktree's checks must
# run through `docker compose run` instead of directly on the host.
_detect_docker_mode() {
  local mode
  mode=$(git -C "$WORKTREE_DIR" config --local agent.install-mode 2>/dev/null || true)
  [ "$mode" = "docker" ] || return 1

  local main_root="${MAIN_ROOT:-}"
  [ -n "$main_root" ] || main_root=$(_main_root_of "$WORKTREE_DIR")
  [ -n "$main_root" ] || return 1

  local override_file="$main_root/docker-compose.override.yml"
  [ -f "$override_file" ] || return 1

  local compose_file="" name
  for name in docker-compose.yml docker-compose.yaml compose.yml; do
    if [ -f "$WORKTREE_DIR/$name" ]; then compose_file="$WORKTREE_DIR/$name"; break; fi
  done
  [ -n "$compose_file" ] || return 1

  local scripts_dir
  scripts_dir="$(_vw_find_dep_scripts "$main_root")"
  [ -n "$scripts_dir" ] || return 1

  local service
  service=$(git -C "$WORKTREE_DIR" config --local agent.install-service 2>/dev/null || true)
  if [ -z "$service" ] && [ -f "$main_root/.coding-crew/dev-commands.json" ]; then
    service=$(grep -o '"docker_service"[[:space:]]*:[[:space:]]*"[^"]*"' "$main_root/.coding-crew/dev-commands.json" 2>/dev/null \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)
  fi
  if [ -z "$service" ]; then
    service=$(bash "$scripts_dir/gen-override.sh" --project-root "$WORKTREE_DIR" --main-root "$main_root" --query services 2>/dev/null | head -1)
  fi
  [ -n "$service" ] || return 1

  local container_src
  container_src=$(bash "$scripts_dir/gen-override.sh" --project-root "$WORKTREE_DIR" --main-root "$main_root" --query container-src 2>/dev/null)
  [ -n "$container_src" ] || return 1

  DOCKER_GIT_ENV_ARGS=()
  DOCKER_GIT_ENV_LINES=()
  while IFS= read -r _git_env_line; do
    if [ -n "$_git_env_line" ]; then
      DOCKER_GIT_ENV_ARGS+=(-e "$_git_env_line")
      DOCKER_GIT_ENV_LINES+=("$_git_env_line")
    fi
  done < <(bash "$scripts_dir/gen-override.sh" --project-root "$WORKTREE_DIR" --main-root "$main_root" --query git-env 2>/dev/null || true)

  DOCKER_MODE=1
  DOCKER_SERVICE="$service"
  DOCKER_CONTAINER_SRC="$container_src"
  DOCKER_COMPOSE_FILE="$compose_file"
  DOCKER_OVERRIDE_FILE="$override_file"
  DEP_SCRIPTS_DIR="$scripts_dir"
}

# CREW_VERIFY_DOCKER=off is the rollback lever, independent of CREW_DEPS, back to the
# always-host behaviour this gate had before docker mode was mechanized here.
if [ "${CREW_VERIFY_DOCKER:-on}" != "off" ]; then
  _detect_docker_mode || true
fi

# ─── commands cache ────────────────────────────────────────────────────────────
#
# .coding-crew/dev-commands.json (see discover-commands.sh / write-commands-cache.sh) is
# committed and human-editable, written once (bootstrap) at MAIN_ROOT, before any worktree
# exists — read here so a worktree's checks use the same commands already discovered,
# instead of re-guessing per worktree with the heuristic chain below. Reuses _main_root_of,
# already defined above for the same MAIN_ROOT-from-a-worktree problem the docker detection
# has.
_CACHE_MAIN_ROOT="${MAIN_ROOT:-}"
if [ -z "$_CACHE_MAIN_ROOT" ]; then
  _CACHE_MAIN_ROOT=$(_main_root_of "$WORKTREE_DIR")
fi
COMMANDS_CACHE=""
[ -n "$_CACHE_MAIN_ROOT" ] && COMMANDS_CACHE="$_CACHE_MAIN_ROOT/.coding-crew/dev-commands.json"

# _load_cached_command <category>
# Prints the cached command for <category> and returns 0 when a usable cache exists —
# including printing nothing for an explicit `null`, the discovery step's own considered
# answer that no local command exists for that category, which must not be second-guessed
# by the heuristic chain below. Returns 1 (nothing printed) only when there is no usable
# cache at all: absent, or missing every recognisable field (a half-written stub) — the only
# case that falls through to steps 1-3.
_load_cached_command() {
  local category="$1"
  [ -n "$COMMANDS_CACHE" ] && [ -f "$COMMANDS_CACHE" ] || return 1
  grep -q '"test"' "$COMMANDS_CACHE" 2>/dev/null || return 1

  local raw
  raw=$(grep -o "\"$category\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" "$COMMANDS_CACHE" 2>/dev/null | head -1 | sed -E "s/\"$category\"[[:space:]]*:[[:space:]]*//")
  case "$raw" in
    "") return 1 ;;
    null) echo ""; return 0 ;;
    \"*\") raw="${raw#\"}"; raw="${raw%\"}"; echo "$raw"; return 0 ;;
    *) return 1 ;;
  esac
}

# ─── check discovery ─────────────────────────────────────────────────────────

# _discover_from_claude_md <category> <worktree-dir>
# Looks for a "Run: `command`" line under a ## <category> section in an agent
# context file (CLAUDE.md, then AGENTS.md — pi and other harnesses use the latter).
# Prints the command if found, empty string otherwise.
_discover_from_claude_md() {
  local category="$1"
  local dir="$2"
  local claude_md=""
  local candidate

  for candidate in "$dir/CLAUDE.md" "$dir/AGENTS.md"; do
    if [ -f "$candidate" ]; then
      claude_md="$candidate"
      break
    fi
  done

  if [ -z "$claude_md" ]; then
    echo ""
    return
  fi

  # Find sections matching the category header, then look for Run: lines
  # Use grep/sed: find lines after a matching ## header until the next ## header
  local in_section=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^## ]]; then
      if echo "$line" | grep -qi "$category"; then
        in_section=1
      else
        in_section=0
      fi
    elif [[ "$in_section" -eq 1 ]] && echo "$line" | grep -q "Run:"; then
      # Extract content between backticks
      local extracted
      extracted=$(echo "$line" | sed "s/.*\`\([^\`]*\)\`.*/\1/")
      if [ "$extracted" != "$line" ] && [ -n "$extracted" ]; then
        echo "$extracted"
        return
      fi
    fi
  done < "$claude_md"
}

# _has_makefile_target <target> <worktree-dir>
# Returns 0 if the Makefile has the specified target, non-zero otherwise.
_has_makefile_target() {
  local target="$1"
  local dir="$2"
  local makefile="$dir/Makefile"

  if [ ! -f "$makefile" ]; then
    return 1
  fi

  grep -qE "^${target}[[:space:]]*:" "$makefile"
}

# _discover_test_command <worktree-dir>
# Returns the test command or empty string if none found.
#
# Every command returned here is bare — no embedded absolute path (no `make -C
# "$dir"`, no `--manifest-path "$dir/..."`, no `--prefix "$dir"`). It relies solely
# on the `cd "$WORKTREE_DIR" && ...` (host) / `cd "$DOCKER_CONTAINER_SRC" && ...`
# (docker) wrappers in the run section below to be correct, matching every other
# script in this repo's cd-then-bare-command convention (host-install.sh). An
# embedded host path would additionally be wrong verbatim inside the container,
# where that path does not exist. Do not run a returned command outside those
# wrappers.
_discover_test_command() {
  local dir="$1"

  # 0. .coding-crew/dev-commands.json, if usable — authoritative, including an explicit null.
  local cached
  if cached=$(_load_cached_command test); then
    echo "$cached"
    return
  fi

  # 1. CLAUDE.md explicit command under Tests section
  local cmd
  cmd=$(_discover_from_claude_md "test" "$dir")
  if [ -n "$cmd" ]; then
    echo "$cmd"
    return
  fi

  # 2. Makefile test target
  if _has_makefile_target "test" "$dir"; then
    echo "make test"
    return
  fi

  # 3. Ecosystem conventions
  # bats: point bats at the directory the .bats files are actually in — a repo
  # with root-level .bats files and no tests/ dir must not be handed tests/.
  if ls "$dir"/tests/*.bats >/dev/null 2>&1; then
    echo "bats tests/"
    return
  fi
  if ls "$dir"/*.bats >/dev/null 2>&1; then
    echo "bats ."
    return
  fi

  # npm/pnpm/yarn: package.json with test script
  if [ -f "$dir/package.json" ] && grep -q '"test"' "$dir/package.json" 2>/dev/null; then
    echo "npm test"
    return
  fi

  # Python: pytest. Match conventionally-named test files only (test_*.py /
  # *_test.py at the root or under tests/), not "any .py file exists" — a
  # stray build/deploy script would otherwise make an unrelated project
  # attempt (and fail) pytest instead of honestly reporting not_run.
  if ls "$dir"/test_*.py >/dev/null 2>&1 || ls "$dir"/*_test.py >/dev/null 2>&1 \
    || ls "$dir"/tests/test_*.py >/dev/null 2>&1 || ls "$dir"/tests/*_test.py >/dev/null 2>&1; then
    echo "pytest"
    return
  fi

  # Go: go test
  if [ -f "$dir/go.mod" ]; then
    echo "go test ./..."
    return
  fi

  # Rust: cargo test
  if [ -f "$dir/Cargo.toml" ]; then
    echo "cargo test"
    return
  fi

  # Ruby: bundle exec rspec
  # No path flag: rspec has no --project-root, and the cd below already sets cwd.
  if [ -f "$dir/Gemfile" ]; then
    echo "bundle exec rspec"
    return
  fi

  echo ""
}

# _discover_lint_command <worktree-dir>
# Returns the lint command or empty string if none found.
_discover_lint_command() {
  local dir="$1"

  # 0. .coding-crew/dev-commands.json, if usable — authoritative, including an explicit null.
  local cached
  if cached=$(_load_cached_command lint); then
    echo "$cached"
    return
  fi

  local cmd
  cmd=$(_discover_from_claude_md "lint" "$dir")
  if [ -n "$cmd" ]; then
    echo "$cmd"
    return
  fi

  # Makefile: lint, then check (verification.md names eslint/lint/check targets)
  local target
  for target in lint check; do
    if _has_makefile_target "$target" "$dir"; then
      echo "make $target"
      return
    fi
  done

  # npm/pnpm/yarn: package.json with a lint script
  if [ -f "$dir/package.json" ] && grep -q '"lint"' "$dir/package.json" 2>/dev/null; then
    echo "npm run lint"
    return
  fi

  # Go: vet ships with the toolchain
  if [ -f "$dir/go.mod" ]; then
    echo "go vet ./..."
    return
  fi

  # Rust: clippy
  if [ -f "$dir/Cargo.toml" ]; then
    echo "cargo clippy"
    return
  fi

  echo ""
}

# _discover_typecheck_command <worktree-dir>
# Returns the type check command or empty string if none found.
_discover_typecheck_command() {
  local dir="$1"

  # 0. .coding-crew/dev-commands.json, if usable — authoritative, including an explicit null.
  local cached
  if cached=$(_load_cached_command typecheck); then
    echo "$cached"
    return
  fi

  local cmd
  cmd=$(_discover_from_claude_md "typecheck" "$dir")
  if [ -n "$cmd" ]; then
    echo "$cmd"
    return
  fi
  cmd=$(_discover_from_claude_md "type check" "$dir")
  if [ -n "$cmd" ]; then
    echo "$cmd"
    return
  fi

  local target
  for target in typecheck types; do
    if _has_makefile_target "$target" "$dir"; then
      echo "make $target"
      return
    fi
  done

  # TypeScript
  if [ -f "$dir/tsconfig.json" ]; then
    echo "npx tsc --noEmit"
    return
  fi

  # Go: build acts as the type check
  if [ -f "$dir/go.mod" ]; then
    echo "go build ./..."
    return
  fi

  echo ""
}

# ─── run checks ──────────────────────────────────────────────────────────────

OVERALL_EXIT=0

echo "Verifying worktree: $WORKTREE_DIR"
if [ "$DOCKER_MODE" -eq 1 ]; then
  echo "  via: docker compose run --rm $DOCKER_SERVICE (container-src: $DOCKER_CONTAINER_SRC)"
fi
echo ""

NOT_RUN=()

# ─── evidence ────────────────────────────────────────────────────────────────
# receipts.sh owns where the evidence lives; empty outside a crew worktree.
RECEIPTS_SCRIPT="$SELF_DIR/receipts.sh"
EVIDENCE_FILE=""
if [ -f "$RECEIPTS_SCRIPT" ]; then
  EVIDENCE_FILE=$(bash "$RECEIPTS_SCRIPT" path verify --dir "$WORKTREE_DIR" ${STEM:+--stem "$STEM"} 2>/dev/null) || EVIDENCE_FILE=""
fi

# One entry per check run or reported not_run, in order — the JSON's `checks` array.
REC_JSON=()
_VW_KIND="base"
_VW_CMD=""

# _json_str <text> — <text> as a JSON string literal. sed/awk, not ${var//…}: that
# expansion's quoting differs between macOS's bash 3.2 and bash 5.2.
_json_str() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\t\r' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}

# _record <label> <command> <result> <exit> <log> — empty command/exit/log are JSON null.
_record() {
  local cat cmd=null ex=null log=null
  cat="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ -n "$2" ] && cmd="$(_json_str "$2")"
  [ -n "$4" ] && ex="$4"
  [ -n "$5" ] && log="$(_json_str "$5")"
  REC_JSON+=("{\"category\": $(_json_str "$cat"), \"requested\": \"$_VW_KIND\", \"command\": $cmd, \"result\": \"$3\", \"exit\": $ex, \"log\": $log}")
}

# ─── output capping ──────────────────────────────────────────────────────────
# A check command's own stdout/stderr is arbitrary and can be very large — a full test
# suite's own verbose output, most of all. Streamed straight through, every caller of
# this script pays for that in full: a human's own terminal, and the orchestrator's own
# trace log (`ctx.log(verify.stdout.trim())` in pipeline.mjs, which also feeds
# console.error) both get an unbounded copy. Bounding it here — the one place the
# command actually runs — bounds it for every caller at once, the same way
# ensure-deps.sh already bounds an install command's output instead of leaving every
# caller to guess a cap of its own.
#
# The tail (not the head) is kept: a failing suite's own error is almost always at the
# end, and pass/fail — the one thing every caller actually gates on — is never inside
# the capped portion, since it is printed by this script, not the command.
# CREW_VERIFY_OUTPUT_LINES overrides the default, per the same escape-hatch convention
# as CREW_DEPS/CREW_VERIFY_DOCKER.
VERIFY_OUTPUT_LINES="${CREW_VERIFY_OUTPUT_LINES:-50}"

# _verify_log_path <label> — where a category's full, uncapped output is persisted (one
# file per category, so a re-run does not clobber a sibling category's log mid-read).
_verify_log_path() {
  local check
  check="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$EVIDENCE_FILE" ]; then
    printf '%s.verify-%s.log' "${EVIDENCE_FILE%.verify.json}" "$check"
  else
    printf '%s/.scratch/verify-%s.log' "$WORKTREE_DIR" "$check"
  fi
}

# _run_capped <label> <out-file> <rc> — prints <out-file>, capped to VERIFY_OUTPUT_LINES
# lines. Under the cap, this is a plain `cat` and nothing else changes — pass or fail.
# Over the cap:
#   - a failing check (rc != 0) keeps a tail: that is almost always where the actual
#     error is, and it is the one case a caller is actually going to read this for.
#   - a passing check (rc == 0) prints nothing of the body at all. A check that passed
#     is not why anyone opens this log, however verbose its own suite is — showing a
#     tail of it anyway would mean a sprint's cumulative trace log still grows with
#     every issue's test-suite size even when nothing ever fails. The full output is
#     still persisted to disk either way, one `cat` away.
_run_capped() {
  local label="$1" out_file="$2" rc="$3"
  local total
  total=$(wc -l < "$out_file" 2>/dev/null | tr -d ' ')
  total="${total:-0}"
  if [ "$total" -le "$VERIFY_OUTPUT_LINES" ]; then
    cat "$out_file"
    return
  fi
  local log
  log="$(_verify_log_path "$label")"
  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  cp "$out_file" "$log" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    echo "... ($total lines omitted — check passed; full output: $log)"
    return
  fi
  echo "... ($((total - VERIFY_OUTPUT_LINES)) earlier lines omitted; full output: $log)"
  tail -n "$VERIFY_OUTPUT_LINES" "$out_file"
}

# _exec_and_report <label> -- <argv...>
# Runs <argv...> (already fully assembled by the caller — a host `bash -c` wrapper, or
# a docker compose invocation), captures its combined stdout/stderr to a temp file,
# prints it through _run_capped, then reports pass/fail and sets OVERALL_EXIT on
# failure. The one place a check command's exit code and its output both originate,
# so every call site gets the same capping and the same pass/fail report for free.
_exec_and_report() {
  local label="$1"
  shift
  local out_file
  out_file="$(mktemp)"
  "$@" >"$out_file" 2>&1
  local rc=$?
  _run_capped "$label" "$out_file" "$rc"
  # Evidence keeps every check's full output; outside it, an extra check's still is.
  local log=""
  if [ -n "$EVIDENCE_FILE" ] || [ "$_VW_KIND" = "extra" ]; then
    log="$(_verify_log_path "$label")"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    if cp "$out_file" "$log" 2>/dev/null; then echo "$label: log: $log"; else log=""; fi
  fi
  rm -f "$out_file"
  if [ "$rc" -eq 0 ]; then
    echo "$label: pass"
    _record "$label" "$_VW_CMD" pass "$rc" "$log"
  else
    echo "$label: fail"
    _record "$label" "$_VW_CMD" fail "$rc" "$log"
    OVERALL_EXIT=1
  fi
}

# _run_category <LABEL> <command> <required>
# Runs one check category. An empty command is reported as not_run and collected
# for the summary — never silently treated as passing.
#
# `required=yes` (TEST only) makes a missing command fatal: with no test command
# nothing was verified at all, so the gate cannot vouch for the branch. For lint
# and typecheck, not_run is loud but non-fatal — many projects legitimately have
# neither, and failing them would stall every sprint on a false positive, which
# is worse for an unattended run than the gap it would close.
_run_category() {
  local label="$1"
  local cmd="$2"
  local required="${3:-no}"
  _VW_CMD="$cmd"

  if [ -z "$cmd" ]; then
    echo "$label: not_run — no command found (checked CLAUDE.md, Makefile, and ecosystem conventions)"
    NOT_RUN+=("$label")
    _record "$label" "" not_run "" ""
    if [ "$required" = "yes" ]; then
      echo "$label: not_run is fatal — nothing was verified"
      OVERALL_EXIT=1
    fi
    return
  fi

  if [ "$DOCKER_MODE" -eq 1 ]; then
    # Docker-in-docker guard: if the discovered command already invokes docker itself
    # — directly, or indirectly through a bare Makefile target ("make <target>" — the
    # only shape _discover_*_command ever returns for one) whose recipe does, including
    # through a variable `make -n` fully expands — wrapping it in an outer
    # `docker compose run` would nest docker inside docker. Run it on the host instead,
    # where the recipe's own docker calls resolve. Shared with docker-install.sh's
    # --install-cmd guard via detect-docker-nesting.sh, so the two heuristics can't drift.
    if [ -n "$DEP_SCRIPTS_DIR" ] && bash "$DEP_SCRIPTS_DIR/detect-docker-nesting.sh" --dir "$WORKTREE_DIR" --cmd "$cmd"; then
      echo "$label: running on host (docker: $DOCKER_SERVICE skipped — '$cmd' recipe already manages docker itself): $cmd"
      # Exported (not `-e`, there is no outer `docker compose run` of ours here) so the
      # recipe's own nested `docker compose run` still picks up GIT_DIR/GIT_COMMON_DIR/
      # hooksPath via the shared override's bare passthrough entries — see gen-override.sh's
      # "Nested docker calls" header comment.
      _exec_and_report "$label" env "${DOCKER_GIT_ENV_LINES[@]}" bash -c 'cd "$1" && eval "$2"' _ "$WORKTREE_DIR" "$cmd"
      return
    fi

    local full_cmd="cd \"$DOCKER_CONTAINER_SRC\" && $cmd"
    echo "$label: running (docker: $DOCKER_SERVICE): $full_cmd"
    _exec_and_report "$label" docker compose -f "$DOCKER_COMPOSE_FILE" -f "$DOCKER_OVERRIDE_FILE" run --rm "${DOCKER_GIT_ENV_ARGS[@]}" "$DOCKER_SERVICE" \
      sh -c "$full_cmd"
    return
  fi

  echo "$label: running: $cmd"
  # Run in the worktree directory so relative paths resolve correctly
  _exec_and_report "$label" bash -c 'cd "$1" && eval "$2"' _ "$WORKTREE_DIR" "$cmd"
}

# Order follows verification.md: type check, then lint, then tests.
_run_category "TYPECHECK" "$(_discover_typecheck_command "$WORKTREE_DIR")" no
echo ""
_run_category "LINT" "$(_discover_lint_command "$WORKTREE_DIR")" no
echo ""
_run_category "TEST" "$(_discover_test_command "$WORKTREE_DIR")" yes

# ─── requested extra checks ──────────────────────────────────────────────────
# Keys of dev-commands.json that are not checks — never runnable through --extra.
_VW_NOT_CHECKS=" test lint typecheck install env credential_target docker_service "
_VW_SEEN=" "
_VW_EXTRAS=()
# Guarded: bash 3.2 (macOS) reads an empty array's "${a[@]}" as unbound under `set -u`.
[ -n "$EXTRA_CHECKS" ] && IFS=',' read -r -a _VW_EXTRAS <<< "$EXTRA_CHECKS"
[ "${#_VW_EXTRAS[@]}" -gt 0 ] && for _vw_extra in "${_VW_EXTRAS[@]}"; do
  _vw_extra="$(printf '%s' "$_vw_extra" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [ -n "$_vw_extra" ] || continue
  case "$_VW_SEEN" in *" $_vw_extra "*) continue ;; esac
  _VW_SEEN="$_VW_SEEN$_vw_extra "
  echo ""
  # Ignored rather than fatal: nothing ran for it, so a criterion that depended on it still
  # has no stated evidence and the review reads it unmet — the gate fails safe either way.
  if ! printf '%s' "$_vw_extra" | grep -qE '^[a-z][a-z0-9_]*$' || [[ "$_VW_NOT_CHECKS" == *" $_vw_extra "* ]]; then
    echo "EXTRA: ignored '$_vw_extra' — not a check category"
    continue
  fi
  _vw_label="$(printf '%s' "$_vw_extra" | tr '[:lower:]' '[:upper:]')"
  _vw_cmd=""
  _vw_cmd="$(_load_cached_command "$_vw_extra")" || _vw_cmd=""
  if [ -z "$_vw_cmd" ]; then
    echo "$_vw_label: not_run — no command for '$_vw_extra' in .coding-crew/dev-commands.json"
    echo "$_vw_label: not_run is fatal — this check was requested"
    NOT_RUN+=("$_vw_label")
    _VW_KIND=extra _record "$_vw_label" "" not_run "" ""
    OVERALL_EXIT=1
    continue
  fi
  _VW_KIND=extra _run_category "$_vw_label" "$_vw_cmd" yes
done

echo ""
# Report bounded coverage explicitly — a category that never ran must not read as
# passing just because the overall gate succeeded.
if [ "${#NOT_RUN[@]}" -gt 0 ]; then
  echo "Verification: coverage gap — not_run: ${NOT_RUN[*]}"
fi

if [ "$OVERALL_EXIT" -eq 0 ]; then
  if [ "${#NOT_RUN[@]}" -gt 0 ]; then
    if [ "${#NOT_RUN[@]}" -eq 1 ]; then CATEGORY_WORD="category"; else CATEGORY_WORD="categories"; fi
    echo "Verification: success — all discovered checks pass (${#NOT_RUN[@]} $CATEGORY_WORD not run)"
  else
    echo "Verification: success — all checks pass"
  fi
else
  echo "Verification: fail — one or more checks did not pass"
fi

# ─── evidence record (the merge receipt) ────────────────────────────────────

# Written pass or fail — a `fail` verdict is what revokes an earlier pass. A failed write is
# reported but never changes the check outcome: this script's exit code must keep meaning
# "the checks passed", and a missing record already fails closed at merge time.
if [ -n "$EVIDENCE_FILE" ]; then
  _vw_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || true)
  _vw_rec_branch=$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ "$OVERALL_EXIT" -eq 0 ]; then _vw_verdict=pass; else _vw_verdict=fail; fi
  # Cached checks nobody asked this run for — named so a reviewer sees what has no evidence.
  _vw_unrun=()
  if [ -n "$COMMANDS_CACHE" ] && [ -f "$COMMANDS_CACHE" ]; then
    while IFS= read -r _vw_key; do
      [[ " test lint typecheck install env credential_target docker_service " == *" $_vw_key "* ]] && continue
      [[ "$_VW_SEEN" == *" $_vw_key "* ]] && continue
      _vw_unrun+=("$(_json_str "$_vw_key")")
    done < <(grep -o '"[a-z][a-z0-9_]*"[[:space:]]*:[[:space:]]*"' "$COMMANDS_CACHE" 2>/dev/null | sed -E 's/^"([a-z0-9_]+)".*/\1/')
  fi
  _vw_join() { local IFS=,; printf '%s' "$*"; }
  _vw_tmp="$EVIDENCE_FILE.tmp.$$"
  if { mkdir -p "$(dirname "$EVIDENCE_FILE")" && printf '{"branch": %s, "commit": %s, "verdict": "%s", "checks": [%s], "not_requested": [%s]}\n' \
      "$(_json_str "$_vw_rec_branch")" "$(_json_str "$_vw_sha")" "$_vw_verdict" \
      "$(_vw_join "${REC_JSON[@]+"${REC_JSON[@]}"}")" "$(_vw_join "${_vw_unrun[@]+"${_vw_unrun[@]}"}")" > "$_vw_tmp" \
      && mv "$_vw_tmp" "$EVIDENCE_FILE"; } 2>/dev/null; then
    echo "Verification record: $EVIDENCE_FILE"
  else
    rm -f "$_vw_tmp" "$EVIDENCE_FILE" 2>/dev/null
    echo "ERROR: cannot write verification record: $EVIDENCE_FILE" >&2
  fi
fi

TRACE_SCRIPT="$SELF_DIR/trace.sh"

# Trace the gate result from the gate itself. The branch name comes from the worktree,
# so the trace cannot disagree with what was actually checked.
if [ -f "$TRACE_SCRIPT" ]; then
  _vw_branch=$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  if [ "$OVERALL_EXIT" -eq 0 ]; then _vw_result=pass; else _vw_result=fail; fi
  _vw_gap=""
  [ "${#NOT_RUN[@]}" -gt 0 ] && _vw_gap=" not_run=${NOT_RUN[*]}"
  bash "$TRACE_SCRIPT" VERIFY "branch=$_vw_branch result=$_vw_result$_vw_gap" 2>/dev/null || true
fi

exit "$OVERALL_EXIT"
