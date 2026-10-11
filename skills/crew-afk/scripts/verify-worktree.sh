#!/usr/bin/env bash
set -uo pipefail

# verify-worktree.sh — run the project's checks in a worktree; exit 0 only if all pass.
# Usage: verify-worktree.sh --dir <worktree-path> [--stem <n>-<slug>]
# Commands come from .coding-crew/dev-commands.json (a `null` is trusted: no command); with no
# usable cache, from CLAUDE.md/AGENTS.md, Makefile targets, then ecosystem conventions. A
# category with no command is not_run, never a pass. In a crew worktree the verdict is recorded
# as verify.json (the merge receipt, see receipts.sh) beside each check's full log.

WORKTREE_DIR=""
STEM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      # Guard: under `set -u` a bare `--dir` would abort on "$2: unbound variable".
      if [ $# -lt 2 ]; then
        echo "ERROR: --dir requires a value" >&2
        echo "Usage: $0 --dir <worktree-path>" >&2
        exit 1
      fi
      WORKTREE_DIR="$2"
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

# Physical path, so it compares string-wise with main_root's `pwd -P` (macOS /var -> /private/var).
WORKTREE_DIR="$(cd "$WORKTREE_DIR" && pwd -P)"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dependencies live in a named volume inside the container, never on the host, so a docker-mode
# check must run there. Any docker signal that fails to resolve falls back to the host path.

# shellcheck source=main-root.sh
. "$SELF_DIR/main-root.sh"
_main_root_of() { main_root "$1"; }

# Same candidate order as ensure-deps.sh.
_vw_find_dep_scripts() {
  local main_root="$1"
  if [ -n "${CREW_DEP_INSTALL_SCRIPTS:-}" ]; then
    [ -f "$CREW_DEP_INSTALL_SCRIPTS/run.sh" ] && printf '%s' "$CREW_DEP_INSTALL_SCRIPTS"
    return 0
  fi
  # A sprint resolved its install once (CREW_INSTALL_DIR); the search below is for hand runs.
  if [ -n "${CREW_INSTALL_DIR:-}" ] && [ -f "$CREW_INSTALL_DIR/dep-install/scripts/run.sh" ]; then
    printf '%s' "$CREW_INSTALL_DIR/dep-install/scripts"
    return 0
  fi
  local root candidate
  for root in "$main_root" "$(cd "$SELF_DIR/../../.." && pwd -P)" "$(cd "$SELF_DIR/../.." && pwd -P)" "${HOME:-}"; do
    [ -n "$root" ] || continue
    for candidate in \
      "$root/.coding-crew/dep-install/scripts" \
      "$root/.claude/skills/dep-install/scripts" \
      "$root/.pi/skills/dep-install/scripts" \
      "$root/.agents/skills/dep-install/scripts" \
      "$root/.github/skills/dep-install/scripts" \
      "$root/skills/dep-install/scripts"; do
      if [ -f "$candidate/run.sh" ]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  done
}

# Where a check runs is dep-install run.sh's decision, the same one a worker's own runs get.
DOCKER_MODE=0
DOCKER_SERVICE=""
DOCKER_CONTAINER_SRC=""
RUN_SCRIPT=""
_VW_MAIN_ROOT="${MAIN_ROOT:-}"
[ -n "$_VW_MAIN_ROOT" ] || _VW_MAIN_ROOT=$(_main_root_of "$WORKTREE_DIR")
_vw_dep_scripts="$(_vw_find_dep_scripts "$_VW_MAIN_ROOT")"
[ -n "$_vw_dep_scripts" ] && RUN_SCRIPT="$_vw_dep_scripts/run.sh"
_VW_RUN_ARGS=(--project-root "$WORKTREE_DIR")
[ -n "$_VW_MAIN_ROOT" ] && _VW_RUN_ARGS+=(--main-root "$_VW_MAIN_ROOT")

# CREW_VERIFY_DOCKER=off: rollback lever to always-host.
if [ "${CREW_VERIFY_DOCKER:-on}" != "off" ] && [ -n "$RUN_SCRIPT" ]; then
  # A docker-mode worktree without the crew override would make run.sh fall back to the host;
  # gen-override.sh is deterministic, so write it now.
  _vw_override="$(git -C "$WORKTREE_DIR" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)/crew-compose.override.yml"
  if [ ! -f "$_vw_override" ] && [ -f "$_vw_dep_scripts/gen-override.sh" ] &&
     bash "$_vw_dep_scripts/resolve-mode.sh" "${_VW_RUN_ARGS[@]}" --no-heuristic 2>/dev/null | grep -qx 'INSTALL_MODE=docker'; then
    bash "$_vw_dep_scripts/gen-override.sh" --project-root "$WORKTREE_DIR" --main-root "${_VW_MAIN_ROOT:-$WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
  _vw_describe="$(bash "$RUN_SCRIPT" "${_VW_RUN_ARGS[@]}" --describe 2>/dev/null || true)"
  if grep -qx 'RUN=docker' <<<"$_vw_describe"; then
    DOCKER_MODE=1
    DOCKER_SERVICE="$(printf '%s\n' "$_vw_describe" | sed -n 's/^SERVICE=//p')"
    DOCKER_CONTAINER_SRC="$(printf '%s\n' "$_vw_describe" | sed -n 's/^CONTAINER_SRC=//p')"
  fi
fi

_CACHE_MAIN_ROOT="${MAIN_ROOT:-}"
if [ -z "$_CACHE_MAIN_ROOT" ]; then
  _CACHE_MAIN_ROOT=$(_main_root_of "$WORKTREE_DIR")
fi
COMMANDS_CACHE=""
[ -n "$_CACHE_MAIN_ROOT" ] && COMMANDS_CACHE="$_CACHE_MAIN_ROOT/.coding-crew/dev-commands.json"

# _load_cached_command <category> — 0 with the command (empty for `null`); 1 only with no usable cache.
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


# First backticked "Run:" command under a `## <category>` heading of CLAUDE.md, else AGENTS.md.
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

  local in_section=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^## ]]; then
      if grep -qi "$category" <<<"$line"; then
        in_section=1
      else
        in_section=0
      fi
    elif [[ "$in_section" -eq 1 ]] && grep -q "Run:" <<<"$line"; then
      local extracted
      extracted=$(echo "$line" | sed "s/.*\`\([^\`]*\)\`.*/\1/")
      if [ "$extracted" != "$line" ] && [ -n "$extracted" ]; then
        echo "$extracted"
        return
      fi
    fi
  done < "$claude_md"
}

_has_makefile_target() {
  local target="$1"
  local dir="$2"
  local makefile="$dir/Makefile"

  if [ ! -f "$makefile" ]; then
    return 1
  fi

  grep -qE "^${target}[[:space:]]*:" "$makefile"
}

# Commands are bare (no embedded path): they rely on the cd in the run section, and a host path
# would be wrong inside the container.
_discover_test_command() {
  local dir="$1"

  local cached
  if cached=$(_load_cached_command test); then
    echo "$cached"
    return
  fi

  local cmd
  cmd=$(_discover_from_claude_md "test" "$dir")
  if [ -n "$cmd" ]; then
    echo "$cmd"
    return
  fi

  if _has_makefile_target "test" "$dir"; then
    echo "make test"
    return
  fi

  # bats wherever the .bats files are: a repo with only root-level ones has no tests/.
  if ls "$dir"/tests/*.bats >/dev/null 2>&1; then
    echo "bats tests/"
    return
  fi
  if ls "$dir"/*.bats >/dev/null 2>&1; then
    echo "bats ."
    return
  fi

  if [ -f "$dir/package.json" ] && grep -q '"test"' "$dir/package.json" 2>/dev/null; then
    echo "npm test"
    return
  fi

  # Conventional test file names only: a stray .py script must not trigger pytest.
  if ls "$dir"/test_*.py >/dev/null 2>&1 || ls "$dir"/*_test.py >/dev/null 2>&1 \
    || ls "$dir"/tests/test_*.py >/dev/null 2>&1 || ls "$dir"/tests/*_test.py >/dev/null 2>&1; then
    echo "pytest"
    return
  fi

  if [ -f "$dir/go.mod" ]; then
    echo "go test ./..."
    return
  fi

  if [ -f "$dir/Cargo.toml" ]; then
    echo "cargo test"
    return
  fi

  if [ -f "$dir/Gemfile" ]; then
    echo "bundle exec rspec"
    return
  fi

  echo ""
}

_discover_lint_command() {
  local dir="$1"

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

  local target
  for target in lint check; do
    if _has_makefile_target "$target" "$dir"; then
      echo "make $target"
      return
    fi
  done

  if [ -f "$dir/package.json" ] && grep -q '"lint"' "$dir/package.json" 2>/dev/null; then
    echo "npm run lint"
    return
  fi

  if [ -f "$dir/go.mod" ]; then
    echo "go vet ./..."
    return
  fi

  if [ -f "$dir/Cargo.toml" ]; then
    echo "cargo clippy"
    return
  fi

  echo ""
}

_discover_typecheck_command() {
  local dir="$1"

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

  if [ -f "$dir/tsconfig.json" ]; then
    echo "npx tsc --noEmit"
    return
  fi

  if [ -f "$dir/go.mod" ]; then
    echo "go build ./..."
    return
  fi

  echo ""
}


OVERALL_EXIT=0

echo "Verifying worktree: $WORKTREE_DIR"
if [ "$DOCKER_MODE" -eq 1 ]; then
  echo "  via: docker compose run --rm $DOCKER_SERVICE (container-src: $DOCKER_CONTAINER_SRC)"
fi
echo ""

NOT_RUN=()

# receipts.sh owns where the evidence lives; empty outside a crew worktree.
RECEIPTS_SCRIPT="$SELF_DIR/receipts.sh"
EVIDENCE_FILE=""
if [ -f "$RECEIPTS_SCRIPT" ]; then
  EVIDENCE_FILE=$(bash "$RECEIPTS_SCRIPT" path verify --dir "$WORKTREE_DIR" ${STEM:+--stem "$STEM"} 2>/dev/null) || EVIDENCE_FILE=""
fi

REC_JSON=()
_VW_KIND="base"
_VW_CMD=""

# sed/awk, not ${var//…}: that expansion's quoting differs between bash 3.2 and 5.2.
_json_str() {
  printf '"%s"' "$(printf '%s' "$1" | tr '\t\r' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}

# _record <label> <command> <result> <exit> <log> — empty command/exit/log are JSON null.
_record() {
  local cat cmd=null ex=null log=null missing=""
  cat="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [ -n "$2" ] && cmd="$(_json_str "$2")"
  [ -n "$4" ] && ex="$4"
  [ -n "$5" ] && log="$(_json_str "$5")"
  [ -n "${6:-}" ] && missing=", \"missing\": $(_json_str "$6")"
  REC_JSON+=("{\"category\": $(_json_str "$cat"), \"command\": $cmd, \"result\": \"$3\", \"exit\": $ex, \"log\": $log$missing}")
}

# Bounded here, where the command runs, so no caller (the orchestrator's trace log included) gets
# an unbounded copy. The tail is kept: a failing suite's error is at the end.
VERIFY_OUTPUT_LINES="${CREW_VERIFY_OUTPUT_LINES:-50}"

# _verify_log_path <label> — one file per category, so a re-run cannot clobber a sibling's log.
_verify_log_path() {
  local check
  check="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$EVIDENCE_FILE" ]; then
    printf '%s/verify-%s.log' "$(dirname "$EVIDENCE_FILE")" "$check"
  else
    printf '%s/.scratch/verify-%s.log' "$WORKTREE_DIR" "$check"
  fi
}

# _run_capped <label> <out-file> <rc> — over the cap a failure prints its tail and a pass prints
# nothing, so the trace log does not grow with suite size; the full output is persisted either way.
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

# A check that rewrites files (an auto-fixing lint) passes on its own edits and leaves the drift to
# the next run. Dirt already present is in the before snapshot, so it is never blamed on the check.
_vw_tree_state() {
  git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort
}

_vw_changed_files() {
  LC_ALL=C comm -3 <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
    | sed -E 's/^\t//; s/^...//' \
    | awk 'NF && !seen[$0]++ { printf "%s%s", (n++ ? ", " : ""), $0 }'
}

# _exec_and_report <label> -- <argv...> — the one place a check's output and exit code originate.
_exec_and_report() {
  local label="$1"
  shift
  local out_file before changed=""
  out_file="$(mktemp)"
  before="$(_vw_tree_state)"
  "$@" >"$out_file" 2>&1
  local rc=$?
  local after
  after="$(_vw_tree_state)"
  [ "$before" = "$after" ] || changed="$(_vw_changed_files "$before" "$after")"
  _run_capped "$label" "$out_file" "$rc"
  # Evidence keeps every check's full output; outside it, a cached extra check's still is.
  local log=""
  if [ -n "$EVIDENCE_FILE" ] || [ "$_VW_KIND" = "extra" ]; then
    log="$(_verify_log_path "$label")"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    if cp "$out_file" "$log" 2>/dev/null; then echo "$label: log: $log"; else log=""; fi
  fi
  # Exit 127: the tool is not installed where the check runs, which no branch change can fix, so the
  # record names it as an environment problem.
  local missing=""
  if [ "$rc" -eq 127 ]; then
    missing="$(sed -n -E 's/.*[: ]([^: ]+): (command )?not found$/\1/p' "$out_file" | head -n 1)"
    [ -n "$missing" ] || missing="${_VW_CMD%% *}"
  fi
  rm -f "$out_file"
  if [ -n "$changed" ]; then
    # Whatever its exit code. solve-issue's run-checks.sh prints the same line.
    echo "$label: modified files: $changed — the check rewrote them: run it, commit the result, and re-run (a check that rewrites files on every run needs a non-mutating command in .coding-crew/dev-commands.json)"
    echo "$label: fail"
    _record "$label" "$_VW_CMD" fail "$rc" "$log"
    OVERALL_EXIT=1
  elif [ "$rc" -eq 0 ]; then
    echo "$label: pass"
    _record "$label" "$_VW_CMD" pass "$rc" "$log"
  elif [ -n "$missing" ]; then
    echo "$label: fail — command not found: $missing (not installed where the check runs — an environment problem, not the code)"
    _record "$label" "$_VW_CMD" fail "$rc" "$log" "$missing"
    OVERALL_EXIT=1
  else
    echo "$label: fail"
    _record "$label" "$_VW_CMD" fail "$rc" "$log"
    OVERALL_EXIT=1
  fi
}

# _run_category <LABEL> <command> <required> — an empty command is not_run, never a pass.
# required=yes makes not_run fatal (nothing was verified); lint and typecheck stay non-fatal, since
# many projects have neither and failing them would stall every sprint.
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
    # A command that runs docker itself (directly or via its make recipe) runs on the host. run.sh
    # decides; it is asked first only so the line below can say where.
    local via
    via="$(bash "$RUN_SCRIPT" "${_VW_RUN_ARGS[@]}" --describe -- "$cmd" 2>/dev/null | sed -n 's/^VIA=//p')"
    case "$via" in
      docker) echo "$label: running (docker: $DOCKER_SERVICE): cd \"$DOCKER_CONTAINER_SRC\" && $cmd" ;;
      *)
        via=host
        if bash "$_vw_dep_scripts/detect-docker-nesting.sh" --dir "$WORKTREE_DIR" --cmd "$cmd"; then
          echo "$label: running on host (docker: $DOCKER_SERVICE skipped — '$cmd' recipe already manages docker itself): $cmd"
        else
          echo "$label: running: $cmd"
        fi
        ;;
    esac
    _exec_and_report "$label" bash "$RUN_SCRIPT" "${_VW_RUN_ARGS[@]}" --via "$via" -- "$cmd"
    return
  fi

  echo "$label: running: $cmd"
  _exec_and_report "$label" bash -c 'cd "$1" && eval "$2"' _ "$WORKTREE_DIR" "$cmd"
}

# Dependency volumes are named by a hash of the lockfiles, so a branch that changed one needs an
# install first; docker-install.sh is install-if-missing. Exit 2 (nothing to install) is no failure.
if [ "$DOCKER_MODE" -eq 1 ] && [ "${CREW_DEPS:-on}" != "off" ] && [ "${CREW_DOCKER_INSTALL:-on}" != "off" ] &&
   [ -f "$_vw_dep_scripts/docker-install.sh" ]; then
  _vw_di_args=(--project-root "$WORKTREE_DIR" --main-root "${_VW_MAIN_ROOT:-$WORKTREE_DIR}")
  _vw_inst="$(_load_cached_command install || true)"
  [ -z "$_vw_inst" ] || _vw_di_args+=(--install-cmd "$_vw_inst")
  _vw_cred="$(_load_cached_command credential_target || true)"
  [ -z "$_vw_cred" ] || _vw_di_args+=(--credential-target "$_vw_cred")
  _VW_CMD="docker-install.sh ${_vw_di_args[*]}"
  echo "DEPS: running (install if missing): $_VW_CMD"
  _exec_and_report "DEPS" bash -c 'bash "$@"; rc=$?; if [ "$rc" -eq 2 ]; then echo "nothing to install"; exit 0; fi; exit "$rc"' \
    _ "$_vw_dep_scripts/docker-install.sh" "${_vw_di_args[@]}"
  echo ""
fi

# Order follows verification.md: type check, then lint, then tests.
_run_category "TYPECHECK" "$(_discover_typecheck_command "$WORKTREE_DIR")" no
echo ""
_run_category "LINT" "$(_discover_lint_command "$WORKTREE_DIR")" no
echo ""
_run_category "TEST" "$(_discover_test_command "$WORKTREE_DIR")" yes

_VW_NOT_CHECKS=" test lint typecheck install install_mode env credential_target docker_service "
# Keys are collected first so a check that reads stdin (docker compose run) cannot swallow the list.
_VW_KEYS=()
_VW_UNSET=()
if [ -n "$COMMANDS_CACHE" ] && [ -f "$COMMANDS_CACHE" ] && grep -q '"test"' "$COMMANDS_CACHE" 2>/dev/null; then
  while IFS= read -r _vw_key; do
    [[ "$_VW_NOT_CHECKS" == *" $_vw_key "* ]] || _VW_KEYS+=("$_vw_key")
  done < <(grep -oE '"[a-z][a-z0-9_]*"[[:space:]]*:[[:space:]]*("|null)' "$COMMANDS_CACHE" 2>/dev/null \
    | sed -E 's/^"([a-z0-9_]+)".*/\1/' | awk '!seen[$0]++')
fi
# Guarded: bash 3.2 (macOS) reads an empty array's "${a[@]}" as unbound under `set -u`.
[ "${#_VW_KEYS[@]}" -gt 0 ] && for _vw_key in "${_VW_KEYS[@]}"; do
  _vw_cmd="$(_load_cached_command "$_vw_key")" || _vw_cmd=""
  if [ -z "$_vw_cmd" ]; then
    _VW_UNSET+=("$_vw_key")
    continue
  fi
  echo ""
  _vw_label="$(printf '%s' "$_vw_key" | tr '[:lower:]' '[:upper:]')"
  _VW_KIND=extra _run_category "$_vw_label" "$_vw_cmd" yes
done

echo ""
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


# Written pass or fail: a `fail` verdict revokes an earlier pass. A failed write never changes the
# exit code; a missing record already fails closed at merge.
if [ -n "$EVIDENCE_FILE" ]; then
  _vw_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || true)
  _vw_rec_branch=$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ "$OVERALL_EXIT" -eq 0 ]; then _vw_verdict=pass; else _vw_verdict=fail; fi
  # The cached categories set to `null` — named so a reviewer sees what has no evidence.
  _vw_unrun=()
  [ "${#_VW_UNSET[@]}" -gt 0 ] && for _vw_key in "${_VW_UNSET[@]}"; do _vw_unrun+=("$(_json_str "$_vw_key")"); done
  _vw_join() { local IFS=,; printf '%s' "$*"; }
  _vw_tmp="$EVIDENCE_FILE.tmp.$$"
  if { mkdir -p "$(dirname "$EVIDENCE_FILE")" && printf '{"branch": %s, "commit": %s, "verdict": "%s", "checks": [%s], "not_configured": [%s]}\n' \
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

# Branch from the worktree, so the trace cannot disagree with what was checked.
if [ -f "$TRACE_SCRIPT" ]; then
  _vw_branch=$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  if [ "$OVERALL_EXIT" -eq 0 ]; then _vw_result=pass; else _vw_result=fail; fi
  _vw_gap=""
  [ "${#NOT_RUN[@]}" -gt 0 ] && _vw_gap=" not_run=${NOT_RUN[*]}"
  # The checked worktree's sprint (crew/<slug>/<issue>), unless an inherited TRACE_LOG wins.
  _vw_slug=""
  case "$_vw_branch" in crew/*/*) _vw_slug="${_vw_branch#crew/}"; _vw_slug="${_vw_slug%%/*}" ;; esac
  (cd "$WORKTREE_DIR" && MAIN_ROOT="${MAIN_ROOT:-$_CACHE_MAIN_ROOT}" \
    bash "$TRACE_SCRIPT" ${_vw_slug:+--feature-slug "$_vw_slug"} --level "$([ "$_vw_result" = pass ] && echo info || echo error)" VERIFY "branch=$_vw_branch result=$_vw_result$_vw_gap") 2>/dev/null || true
fi

exit "$OVERALL_EXIT"
