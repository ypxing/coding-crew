#!/usr/bin/env bash
set -uo pipefail

# ensure-deps.sh — make a directory ready to run the project's own checks.
#
# Usage:
#   ensure-deps.sh --dir <path> [--slug <issue-slug>] [--stem <n>-<slug>] [--timeout <sec, default 1800>]
#
#   --stem names this issue's own dispatch subdirectory, like its other dispatch files (the slug when absent).
#

# Prints one `DEPS:` line and exits 0 on every install outcome: present | installed <cmd> | none |
# docker (left to the worker's dep-install) | docker-present | docker-installed <cmd> |
# failed <cmd> (exit N) (see <log>) | skipped (CREW_DEPS=off); the orchestrator decides what a
# failure means. A gate cannot invoke a skill, so what verify-worktree.sh depends on is mechanism
# here; every install decision is delegated to dep-install's scripts or the cached "install".

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=main-root.sh
. "$SELF_DIR/main-root.sh"

DIR=""
SLUG=""
STEM=""
FEATURE_SLUG_ARG=""
TIMEOUT=1800

_usage() {
  echo "Usage: $0 --dir <path> [--slug <issue-slug>] [--stem <n>-<slug>] [--feature-slug <slug>] [--timeout <sec>]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--slug|--stem|--feature-slug|--timeout)
      # Guard: under `set -u` a bare flag would abort on an unbound variable.
      if [ $# -lt 2 ]; then echo "ERROR: $1 requires a value" >&2; _usage; exit 1; fi
      case "$1" in
        --dir) DIR="$2" ;;
        --slug) SLUG="$2" ;;
        --stem) STEM="$2" ;;
        --feature-slug) FEATURE_SLUG_ARG="$2" ;;
        --timeout) TIMEOUT="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; _usage; exit 1 ;;
  esac
done

# A usage error still exits non-zero: the always-exit-0 rule is about install outcomes.
if [ -z "$DIR" ]; then echo "ERROR: --dir <path> is required" >&2; _usage; exit 1; fi
if [ ! -d "$DIR" ]; then echo "ERROR: directory does not exist: $DIR" >&2; exit 1; fi
DIR="$(cd "$DIR" && pwd -P)"

TRACE_SCRIPT="$SELF_DIR/trace.sh"

# _sprint_dir — inherited SPRINT_DIR, else --feature-slug's; empty outside a sprint. --slug with
# neither exits 2 unless CREW_ORCHESTRATED=1 (a dispatched agent's stray call).
_sprint_dir() {
  if [ -n "${SPRINT_DIR:-}" ]; then printf '%s' "$SPRINT_DIR"; return; fi
  if [ -n "$FEATURE_SLUG_ARG" ]; then
    local root="${MAIN_ROOT:-$(main_root "$DIR" || true)}"
    [ -z "$root" ] || printf '%s' "$root/.scratch/$FEATURE_SLUG_ARG"
  fi
}

if [ -n "$SLUG" ] && [ -z "${SPRINT_DIR:-}" ] && [ -z "$FEATURE_SLUG_ARG" ] && [ "${CREW_ORCHESTRATED:-}" != 1 ]; then
  echo "ERROR: ensure-deps.sh --slug needs a sprint — pass --feature-slug <slug> (or run it with SPRINT_DIR set)" >&2
  _usage
  exit 2
fi

MARKER_DIR="$(_sprint_dir)"
MARKER=""
if [ -n "$SLUG" ] && [ -n "$MARKER_DIR" ]; then
  MARKER="$MARKER_DIR/dispatch/${STEM:-$SLUG}/deps"
fi

# _report <outcome-line> <marker-suffix> — the single exit point: prints, caches, traces, exits 0.
_report() {
  local line="$1" kind="${2:-}"
  echo "DEPS: $line"
  if [ -n "$MARKER" ] && [ -n "$kind" ]; then
    mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
    rm -f "$MARKER.ok" "$MARKER.skip" 2>/dev/null || true
    printf '%s\n' "$line" > "$MARKER.$kind" 2>/dev/null || true
  fi
  if [ -f "$TRACE_SCRIPT" ]; then
    # From $DIR: trace.sh falls back to its cwd's repo, which must be the one _sprint_dir read.
    local level=info
    case "$line" in failed*) level=error ;; esac
    (cd "$DIR" && bash "$TRACE_SCRIPT" ${MARKER_DIR:+--log "$MARKER_DIR/traces/orchestrator.log"} --level "$level" DEPS "dir=$DIR${SLUG:+ slug=$SLUG} $line") 2>/dev/null || true
  fi
  exit 0
}

# _debug_log_path — the caller discards stderr, so a failed command's full output persists here:
# beside the marker in a sprint, else the target directory's .scratch.
_debug_log_path() {
  if [ -n "$MARKER" ]; then
    printf '%s' "$MARKER.log"
  else
    printf '%s' "$DIR/.scratch/deps-install.log"
  fi
}

_docker_log_path() {
  local stem="${STEM:-${SLUG:-install}}"
  if [ -n "$MARKER_DIR" ]; then
    printf '%s' "$MARKER_DIR/docker-install-$stem.log"
  else
    printf '%s' "$DIR/.scratch/docker-install-$stem.log"
  fi
}

# _persist_log <dest> <src> — best-effort, never fails the caller. Stamped with UTC time: the file
# is overwritten by the next failure, so the stamp tells a fresh failure from a stale one.
_persist_log() {
  local dest="$1" src="$2"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 0
  { printf '--- %s ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$src"; } > "$dest" 2>/dev/null || true
}

if [ "${CREW_DEPS:-on}" = "off" ]; then
  _report "skipped"
fi

# Resolved before the presence guard: a documented install command is a dependency step even when
# no known manifest exists. A missing cache or a `null` means no override.
MAIN_ROOT_EFFECTIVE="${MAIN_ROOT:-}"
if [ -z "$MAIN_ROOT_EFFECTIVE" ]; then
  # The main checkout: the cache lives there, and the stale-link check compares against it.
  MAIN_ROOT_EFFECTIVE="$(main_root "$DIR" || echo "$DIR")"
fi
_cached_install_command() {
  local cache="$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json"
  [ -f "$cache" ] || return 0
  grep -o '"install"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}
CACHED_INSTALL="$(_cached_install_command)"

# _cached_credential_target — forwarded to docker-install.sh only; missing or `null` is no override.
_cached_credential_target() {
  local cache="$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json"
  [ -f "$cache" ] || return 0
  grep -o '"credential_target"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}
CACHED_CREDENTIAL_TARGET="$(_cached_credential_target)"

# _merge_mode_cache <docker|host> [service] — record the mode (and service) in the committed cache
# so later sprints trust it. Rebuilds the JSON like write-commands-cache.sh rather than calling it:
# that script has no install path reachable from here.
_merge_mode_cache() {
  local mode_val="$1" service_val="${2:-}" cache="$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json" old=""
  # write-commands-cache.sh's FIELDS — keep in sync.
  local fields=(test lint typecheck install env credential_target coverage integration)
  [ -f "$cache" ] && old="$(cat "$cache" 2>/dev/null || true)"
  # An empty detection must not erase a service a prior call found.
  if [ -z "$service_val" ]; then
    service_val="$(printf '%s' "$old" | grep -o '"docker_service"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)"
  fi
  local body="" f v
  for f in "${fields[@]}"; do
    v="$(printf '%s' "$old" | grep -o "\"$f\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" \
      | head -1 | sed -E "s/\"$f\"[[:space:]]*:[[:space:]]*//")"
    [ -n "$v" ] || continue
    [ -n "$body" ] && body="$body, "
    body="$body\"$f\": $v"
  done
  [ -n "$body" ] && body="$body, "
  [ -n "$service_val" ] && body="$body\"docker_service\": \"$service_val\", "
  mkdir -p "$MAIN_ROOT_EFFECTIVE/.coding-crew" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp "$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json.XXXXXX" 2>/dev/null)" || return 0
  printf '{%s"install_mode": "%s"}\n' "$body" "$mode_val" > "$tmp"
  mv "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
}

# No install logic lives here: host-install.sh is the only place that knows package managers.
# install.sh also ships a platform-neutral copy at .coding-crew/dep-install/scripts.
_script_roots() {
  local root
  [ -n "${MAIN_ROOT:-}" ] && printf '%s\n' "$MAIN_ROOT"
  root=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$root" ] && printf '%s\n' "$root"
  # The repo this script was installed into (.../.pi/skills/crew-afk/scripts, or this source repo).
  printf '%s\n' "$(cd "$SELF_DIR/../../.." && pwd -P)"
  printf '%s\n' "$(cd "$SELF_DIR/../.." && pwd -P)"
  [ -n "${HOME:-}" ] && printf '%s\n' "$HOME"
}

_find_dep_scripts() {
  if [ -n "${CREW_DEP_INSTALL_SCRIPTS:-}" ]; then
    if [ -f "$CREW_DEP_INSTALL_SCRIPTS/detect-mode.sh" ]; then
      printf '%s' "$CREW_DEP_INSTALL_SCRIPTS"
    fi
    return 0
  fi
  # A sprint resolved its install once (CREW_INSTALL_DIR); the search below is for hand runs.
  if [ -n "${CREW_INSTALL_DIR:-}" ] && [ -f "$CREW_INSTALL_DIR/dep-install/scripts/detect-mode.sh" ]; then
    printf '%s' "$CREW_INSTALL_DIR/dep-install/scripts"
    return 0
  fi
  local root candidate
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for candidate in \
      "$root/.coding-crew/dep-install/scripts" \
      "$root/.claude/skills/dep-install/scripts" \
      "$root/.pi/skills/dep-install/scripts" \
      "$root/.agents/skills/dep-install/scripts" \
      "$root/.github/skills/dep-install/scripts" \
      "$root/skills/dep-install/scripts"; do
      if [ -f "$candidate/detect-mode.sh" ] && [ -f "$candidate/host-install.sh" ]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  done < <(_script_roots)
}

DEP_SCRIPTS="$(_find_dep_scripts)"
if [ -z "$DEP_SCRIPTS" ]; then
  _report "none" skip
fi

# Docker volumes are named by the lockfiles and filled only by docker-install.sh, so a host-side
# node_modules says nothing about them: docker mode skips the presence guard.
MODE="$(bash "$DEP_SCRIPTS/detect-mode.sh" --project-root "$DIR" 2>/dev/null || echo USE_HOST)"
SKIP_PRESENCE_GUARD=0
[ "$MODE" = "USE_DOCKER" ] && SKIP_PRESENCE_GUARD=1

# A present dep dir needs no install, so a resumed sprint or a .worktreeinclude repo costs nothing.
# One row per ecosystem: "<dep dir>:<manifest> …"; no manifest at all means no dependency step.
if [ "$SKIP_PRESENCE_GUARD" -eq 0 ]; then
_ECOSYSTEMS=(
  "node_modules:package-lock.json pnpm-lock.yaml yarn.lock bun.lockb package.json"
  ".venv:uv.lock poetry.lock requirements.txt pyproject.toml Pipfile"
  "vendor/bundle:Gemfile.lock Gemfile"
  "vendor:composer.json"
  "target:Cargo.toml"
  "deps:mix.exs"
)

_manifests_differ_from_main() {
  local m
  [ "$MAIN_ROOT_EFFECTIVE" != "$DIR" ] || return 1
  for m in $1; do
    [ -e "$DIR/$m" ] || [ -e "$MAIN_ROOT_EFFECTIVE/$m" ] || continue
    cmp -s "$DIR/$m" "$MAIN_ROOT_EFFECTIVE/$m" || return 0
  done
  return 1
}

HAS_MANIFEST=0
for _row in "${_ECOSYSTEMS[@]}"; do
  _depdir="${_row%%:*}"
  _manifests="${_row#*:}"
  for _m in $_manifests; do
    [ -e "$DIR/$_m" ] || continue
    HAS_MANIFEST=1
    if [ -d "$DIR/$_depdir" ]; then
      # A dep dir linked from the main checkout was installed for that checkout's branch; when a
      # manifest here differs from it, the link is stale — drop it and install.
      if [ -L "$DIR/$_depdir" ] && _manifests_differ_from_main "$_manifests"; then
        rm -f "$DIR/$_depdir"
      else
        _report "present" ok
      fi
    fi
    break
  done
done

# A Makefile install/deps target is a dependency step: host-install.sh looks for it first.
if [ "$HAS_MANIFEST" -eq 0 ] && [ -f "$DIR/Makefile" ] &&
   grep -qE '^(install|deps)[[:space:]]*:' "$DIR/Makefile" 2>/dev/null; then
  HAS_MANIFEST=1
fi

# Go and .NET vendor nothing, so there is no dep dir to find; their install is idempotent.
if [ "$HAS_MANIFEST" -eq 0 ]; then
  for _m in go.sum go.mod pom.xml; do
    [ -e "$DIR/$_m" ] && { HAS_MANIFEST=1; break; }
  done
fi

# A documented install override is a dependency step even with no manifest (a custom bootstrap).
if [ "$HAS_MANIFEST" -eq 0 ] && [ -n "$CACHED_INSTALL" ]; then
  HAS_MANIFEST=1
fi

if [ "$HAS_MANIFEST" -eq 0 ]; then
  _report "none" skip
fi

# `none` and `failed` are cached so a round does not re-probe or re-run a failing install. The
# guard above already ran, so a worktree that has since got its deps still reports `present`.
if [ -n "$MARKER" ] && [ -f "$MARKER.skip" ]; then
  _report "$(cat "$MARKER.skip" 2>/dev/null || echo none)"
fi
fi  # SKIP_PRESENCE_GUARD

# Generating the override and installing in the container are deterministic, so docker-install.sh
# does them here; recovering from a failure stays with the dep-install skill. Volumes are keyed by
# lockfile hash, so every worktree call runs it (`docker-present` when already filled).
if [ "$MODE" = "USE_DOCKER" ]; then
  # The key detect-mode.sh checks first: without it a verdict reached by the Makefile heuristic is
  # never written, and the worker's own check concludes host mode and never installs.
  git -C "$DIR" config --local agent.install-mode docker 2>/dev/null || true

  if [ -z "$SLUG" ]; then
    # The MAIN_ROOT call records the mode (and service) in the committed cache and installs nothing:
    # the git-config write can lose a lock race, and only the cache reaches every copy of
    # detect-mode.sh and survives to the next sprint.
    DETECTED_SERVICE=""
    [ -f "$DEP_SCRIPTS/detect-service.sh" ] &&
      DETECTED_SERVICE="$(bash "$DEP_SCRIPTS/detect-service.sh" --project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" 2>/dev/null || true)"
    _merge_mode_cache docker "$DETECTED_SERVICE"

    # A generated repo-root override (volume keys wt_<project>_…) would auto-load on a bare compose
    # call with stale volume names; remove it, never a project's own committed one.
    _proj_slug="$(basename "$MAIN_ROOT_EFFECTIVE" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_*$//')"
    if [ -f "$MAIN_ROOT_EFFECTIVE/docker-compose.override.yml" ] &&
       grep -Eq "^[[:space:]]+wt_${_proj_slug}_[A-Za-z0-9_]*:[[:space:]]*\$" "$MAIN_ROOT_EFFECTIVE/docker-compose.override.yml" 2>/dev/null; then
      rm -f "$MAIN_ROOT_EFFECTIVE/docker-compose.override.yml"
    fi
    _report "docker"
  fi

  # CREW_DOCKER_INSTALL=off: rollback lever to always deferring to the worker.
  DOCKER_INSTALL_SCRIPT="$DEP_SCRIPTS/docker-install.sh"
  if [ "${CREW_DOCKER_INSTALL:-on}" = "off" ] || [ ! -f "$DOCKER_INSTALL_SCRIPT" ]; then
    _report "docker"
  fi

  DOCKER_OUT="$(mktemp)"
  trap 'rm -f "$DOCKER_OUT"' EXIT
  DOCKER_ARGS=(--project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" --timeout "$TIMEOUT")
  # Forward the cached overrides, or docker-install.sh would run its own lockfile table's command.
  [ -n "$CACHED_INSTALL" ] && DOCKER_ARGS+=(--install-cmd "$CACHED_INSTALL")
  [ -n "$CACHED_CREDENTIAL_TARGET" ] && DOCKER_ARGS+=(--credential-target "$CACHED_CREDENTIAL_TARGET")
  # tee, so a foreground caller sees the install live; PIPESTATUS[0] is the install's exit code.
  bash "$DOCKER_INSTALL_SCRIPT" "${DOCKER_ARGS[@]}" 2>&1 | tee "$DOCKER_OUT"
  DOCKER_RC=${PIPESTATUS[0]}
  DOCKER_CMD="$(grep -m1 '^Running: ' "$DOCKER_OUT" 2>/dev/null | sed 's/^Running: //')"
  [ -n "$DOCKER_CMD" ] || DOCKER_CMD="docker-install.sh"

  case "$DOCKER_RC" in
    0)
      if grep -q '^Present: ' "$DOCKER_OUT" 2>/dev/null; then
        _report "docker-present" ok
      fi
      _report "docker-installed $DOCKER_CMD" ok
      ;;
    2)
      # Nothing docker-install.sh can do. The override is still wanted by every run.sh call and bare
      # `docker compose`, so write it best-effort and defer to the worker.
      [ -f "$DEP_SCRIPTS/gen-override.sh" ] &&
        bash "$DEP_SCRIPTS/gen-override.sh" --project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" >/dev/null 2>&1 || true
      _report "docker"
      ;;
    *)
      DOCKER_LOG="$(_docker_log_path)"
      _persist_log "$DOCKER_LOG" "$DOCKER_OUT"
      echo "--- docker-install.sh output (tail) ---" >&2
      tail -n 20 "$DOCKER_OUT" >&2
      echo "--- end; full output saved to $DOCKER_LOG ---" >&2
      _report "failed $DOCKER_CMD (exit $DOCKER_RC) (see $DOCKER_LOG)"
      ;;
  esac
elif [ -z "$SLUG" ]; then
  # Cache the host verdict too, so later calls skip detect-mode.sh's Makefile dry-run loop.
  _merge_mode_cache host
fi

# Capped, because a hung install would hang the sprint. macOS ships no `timeout`: run uncapped
# then — the cap is a safety net, not the contract.
TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

if [ -n "$CACHED_INSTALL" ]; then
  # Run in $DIR, the target host-install.sh would use. A Makefile target that calls docker compose
  # passes through the docker shim unchanged: this is host mode, with no crew override.
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" bash -c 'cd "$1" && eval "$2"' _ "$DIR" "$CACHED_INSTALL" \
      2>&1 | tee "$OUT_FILE"
  else
    bash -c 'cd "$1" && eval "$2"' _ "$DIR" "$CACHED_INSTALL" 2>&1 | tee "$OUT_FILE"
  fi
  RC=${PIPESTATUS[0]}
  CMD="$CACHED_INSTALL"

  if [ "$RC" -eq 0 ]; then
    _report "installed $CMD" ok
  fi
  # Any non-zero exit is a failure: exit 2 means "no method found" only from host-install.sh.
  DEPS_LOG="$(_debug_log_path)"
  _persist_log "$DEPS_LOG" "$OUT_FILE"
  echo "--- discovered install command output (tail) ---" >&2
  tail -n 20 "$OUT_FILE" >&2
  echo "--- end; full output saved to $DEPS_LOG ---" >&2
  _report "failed $CMD (exit $RC) (see $DEPS_LOG)" skip
fi

if [ -n "$TIMEOUT_BIN" ]; then
  "$TIMEOUT_BIN" "$TIMEOUT" bash "$DEP_SCRIPTS/host-install.sh" --project-root "$DIR" \
    --main-root "$MAIN_ROOT_EFFECTIVE" 2>&1 | tee "$OUT_FILE"
else
  bash "$DEP_SCRIPTS/host-install.sh" --project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" \
    2>&1 | tee "$OUT_FILE"
fi
RC=${PIPESTATUS[0]}

CMD="$(grep -m1 '^Running: ' "$OUT_FILE" 2>/dev/null | sed 's/^Running: //')"
[ -n "$CMD" ] || CMD="host-install.sh"

case "$RC" in
  0) _report "installed $CMD" ok ;;
  2) _report "none" skip ;;
  *)
    DEPS_LOG="$(_debug_log_path)"
    _persist_log "$DEPS_LOG" "$OUT_FILE"
    echo "--- host-install.sh output (tail) ---" >&2
    tail -n 20 "$OUT_FILE" >&2
    echo "--- end; full output saved to $DEPS_LOG ---" >&2
    _report "failed $CMD (exit $RC) (see $DEPS_LOG)" skip
    ;;
esac
