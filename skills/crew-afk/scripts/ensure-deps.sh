#!/usr/bin/env bash
set -uo pipefail

# ensure-deps.sh — make a directory ready to run the project's own checks.
#
# Usage:
#   ensure-deps.sh --dir <path> [--slug <issue-slug>] [--timeout <sec, default 600>]
#
# Output — exactly one `DEPS:` line, always exit 0:
#
#   DEPS: present            dep dir already there (inherited via .worktreeinclude, or a prior run)
#   DEPS: installed <cmd>
#   DEPS: none               no manifest / no install method found — not a failure
#   DEPS: docker             detect-mode.sh says USE_DOCKER → deferred to the worker's dep-install
#   DEPS: failed <cmd> (exit N)
#   DEPS: skipped            CREW_DEPS=off
#
# Why this is a script and not a step in a worker's skill
#   dep-install is failure-triggered, which is right for a human's `solve-issue` run: their
#   worktree usually already has deps, so an unconditional skill read plus an install per
#   issue buys nothing. A sprint is the opposite case — the orchestrator creates every
#   worktree fresh, and one consumer of the deps is not a model at all. verify-worktree.sh
#   runs `npm test` / `pytest` in the worktree and has no dep recovery path, because a gate
#   cannot invoke a skill. Provisioning that a gate depends on has to be mechanism.
#
#   There is no judgement on the host path, so there is nothing here for a model to decide:
#   this script owns no package-manager knowledge of its own and delegates every install
#   decision to dep-install's own detect-mode.sh / host-install.sh. Docker mode *is*
#   judgement (an override has to be generated), so it is deferred, not handled.
#
# Never exits non-zero
#   A repo with no dependency step must not stall a sprint, and a failed install must not
#   either: the consequence is caught by verify-worktree.sh, which already fails closed.
#   Failing fast here would save one dispatch and cost a whole sprint on any environment
#   quirk host-install.sh mishandles — the same rule dependency-audit.sh follows.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIR=""
SLUG=""
TIMEOUT=600

_usage() {
  echo "Usage: $0 --dir <path> [--slug <issue-slug>] [--timeout <sec>]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--slug|--timeout)
      # Guard before reading $2: under `set -u` a bare flag would abort with an
      # unbound-variable error instead of the usage message.
      if [ $# -lt 2 ]; then echo "ERROR: $1 requires a value" >&2; _usage; exit 1; fi
      case "$1" in
        --dir) DIR="$2" ;;
        --slug) SLUG="$2" ;;
        --timeout) TIMEOUT="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; _usage; exit 1 ;;
  esac
done

# A usage error is still an error: exiting 0 on a typo'd flag would report "deps are fine"
# about a directory nobody looked at. The always-exit-0 rule is about install *outcomes*.
if [ -z "$DIR" ]; then echo "ERROR: --dir <path> is required" >&2; _usage; exit 1; fi
if [ ! -d "$DIR" ]; then echo "ERROR: directory does not exist: $DIR" >&2; exit 1; fi
DIR="$(cd "$DIR" && pwd -P)"

TRACE_SCRIPT="$SELF_DIR/trace.sh"

# _sprint_dir — where this sprint's dispatch markers live, or empty outside a sprint.
# Resolved the same way trace.sh resolves its log, so the two agree about whether a
# sprint exists at all.
_sprint_dir() {
  if [ -n "${SPRINT_DIR:-}" ]; then printf '%s' "$SPRINT_DIR"; return; fi
  local root="${MAIN_ROOT:-}"
  if [ -z "$root" ]; then
    root=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
  fi
  [ -n "$root" ] && [ -f "$root/.scratch/sprint.env" ] || return 0
  # shellcheck disable=SC1091
  ( . "$root/.scratch/sprint.env" 2>/dev/null; printf '%s' "${SPRINT_DIR:-}" )
}

MARKER_DIR=""
MARKER=""
if [ -n "$SLUG" ]; then
  MARKER_DIR="$(_sprint_dir)"
  [ -n "$MARKER_DIR" ] && MARKER="$MARKER_DIR/dispatch/$SLUG.deps"
fi

# _report <outcome-line> <marker-suffix> — the single exit point.
# Prints the one DEPS: line, records the marker cache, traces, and exits 0.
_report() {
  local line="$1" kind="${2:-}"
  echo "DEPS: $line"
  if [ -n "$MARKER" ] && [ -n "$kind" ]; then
    mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true
    rm -f "$MARKER.ok" "$MARKER.skip" 2>/dev/null || true
    printf '%s\n' "$line" > "$MARKER.$kind" 2>/dev/null || true
  fi
  if [ -f "$TRACE_SCRIPT" ]; then
    bash "$TRACE_SCRIPT" DEPS "dir=$DIR${SLUG:+ slug=$SLUG} $line" 2>/dev/null || true
  fi
  exit 0
}

# ─── 1. escape hatch ─────────────────────────────────────────────────────────
# Mirrors CREW_RECEIPTS=off: an operator debugging the pipeline can take one
# mechanism out of it without editing the orchestrator.
if [ "${CREW_DEPS:-on}" = "off" ]; then
  _report "skipped"
fi

# ─── 2. the presence guard ───────────────────────────────────────────────────
# The real guard, and the reason a resumed sprint and a .worktreeinclude repo cost
# nothing: if the ecosystem's dep dir is already in $DIR there is nothing to do, and no
# marker, no round counter and no cache is consulted to establish that.
#
# One row per ecosystem: "<dep dir>:<manifest> <manifest> …". A manifest with no dep dir
# means an install is worth attempting; no manifest at all means this repo has no
# dependency step.
_ECOSYSTEMS=(
  "node_modules:package-lock.json pnpm-lock.yaml yarn.lock bun.lockb package.json"
  ".venv:uv.lock poetry.lock requirements.txt pyproject.toml Pipfile"
  "vendor/bundle:Gemfile.lock Gemfile"
  "vendor:composer.json"
  "target:Cargo.toml"
  "deps:mix.exs"
)

HAS_MANIFEST=0
for _row in "${_ECOSYSTEMS[@]}"; do
  _depdir="${_row%%:*}"
  _manifests="${_row#*:}"
  for _m in $_manifests; do
    [ -e "$DIR/$_m" ] || continue
    HAS_MANIFEST=1
    if [ -d "$DIR/$_depdir" ]; then
      _report "present" ok
    fi
    break
  done
done

# A Makefile install/deps target is a dependency step even with no manifest file — it is
# the first thing host-install.sh looks for, so it must not be filtered out before it.
if [ "$HAS_MANIFEST" -eq 0 ] && [ -f "$DIR/Makefile" ] &&
   grep -qE '^(install|deps)[[:space:]]*:' "$DIR/Makefile" 2>/dev/null; then
  HAS_MANIFEST=1
fi

# Go and .NET vendor nothing by default: there is no dep dir to look for, so the presence
# guard cannot short-circuit them and `go mod download` is left to be the idempotent thing
# it already is.
if [ "$HAS_MANIFEST" -eq 0 ]; then
  for _m in go.sum go.mod pom.xml; do
    [ -e "$DIR/$_m" ] && { HAS_MANIFEST=1; break; }
  done
fi

if [ "$HAS_MANIFEST" -eq 0 ]; then
  _report "none" skip
fi

# ─── 2b. the marker cache ────────────────────────────────────────────────────
# `none` and `failed` are the two outcomes that would otherwise be re-probed every round
# for the same worktree — one of them runs a full install command to learn nothing new.
# Cache them. The guard above has already run, so a worktree that has since acquired its
# deps reports `present` regardless of what this file says.
if [ -n "$MARKER" ] && [ -f "$MARKER.skip" ]; then
  _report "$(cat "$MARKER.skip" 2>/dev/null || echo none)"
fi

# ─── 3. resolve dep-install's scripts ────────────────────────────────────────
# No install logic lives here. host-install.sh stays the only place that knows package
# managers, so this only has to find it — and it must find it without knowing which of the
# four platform skill directories a consuming repo installed, which is why install.sh also
# ships one platform-neutral copy at .coding-crew/dep-install/scripts.
_script_roots() {
  local root
  [ -n "${MAIN_ROOT:-}" ] && printf '%s\n' "$MAIN_ROOT"
  root=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$root" ] && printf '%s\n' "$root"
  # The repo this script was installed into, whether that is .../.pi/skills/crew-afk/scripts
  # or this source repo's skills/crew-afk/scripts.
  printf '%s\n' "$(cd "$SELF_DIR/../../.." && pwd -P)"
  printf '%s\n' "$(cd "$SELF_DIR/../.." && pwd -P)"
}

_find_dep_scripts() {
  if [ -n "${CREW_DEP_INSTALL_SCRIPTS:-}" ]; then
    if [ -f "$CREW_DEP_INSTALL_SCRIPTS/detect-mode.sh" ]; then
      printf '%s' "$CREW_DEP_INSTALL_SCRIPTS"
    fi
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

# ─── 4. docker mode: warm the shared volume once, then just check it happened ────────────
# The judgement half (env/credential setup, choosing a service or command by hand, and
# recovering from an install failure) stays with the dep-install skill — that is still
# the worker's own up-front invocation, unchanged. What is left has no judgement in it:
# generating the override and running the ecosystem's own install command inside the
# container are both deterministic, the same way host-install.sh already is on the host
# path, so docker-install.sh (dep-install's docker-mode sibling of host-install.sh) can do
# it here.
#
# Docker volumes are shared across every worktree of this MAIN_ROOT *by design* — that is
# the whole point of caching deps once instead of once per worktree — so the install must
# run exactly once, not once per worktree. `--slug` is always passed for a worktree call
# and never for the one MAIN_ROOT call this orchestrator makes before any worktree exists
# (see sprint.mjs), so its absence is already the signal for "this is the place to do the
# real work"; a worktree call only ever checks whether that already happened.
MAIN_ROOT_EFFECTIVE="${MAIN_ROOT:-}"
if [ -z "$MAIN_ROOT_EFFECTIVE" ]; then
  MAIN_ROOT_EFFECTIVE="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || echo "$DIR")"
fi
DOCKER_MARKER="$MAIN_ROOT_EFFECTIVE/.scratch/docker-install.done"

MODE="$(bash "$DEP_SCRIPTS/detect-mode.sh" --project-root "$DIR" 2>/dev/null || echo USE_HOST)"
if [ "$MODE" = "USE_DOCKER" ]; then
  # Persist the verdict into *this* worktree's local git config — the exact key
  # detect-mode.sh checks first and solve-issue Sec.2 already reads. Without this, a
  # verdict reached only via detect-mode.sh's Makefile heuristic (no explicit
  # agent.install-mode set, no override file yet) is never written anywhere: the
  # worker's own up-front check sees neither signal, silently concludes host mode, and
  # skips dep-install entirely — the worktree never gets its deps at all, in any mode.
  # Writing it here turns an inferred verdict into the explicit one every downstream
  # reader already trusts.
  git -C "$DIR" config --local agent.install-mode docker 2>/dev/null || true

  if [ -n "$SLUG" ]; then
    # A worktree call: the shared install already happened or it did not. Either way
    # there is nothing for a worktree to install into a volume every other worktree
    # already shares — a branch that adds its own new dependency is exactly the
    # "trivial impact" case dep-install's own retry rule already covers reactively
    # (module-not-found → re-run install), so it is left there rather than duplicated.
    if [ -f "$DOCKER_MARKER" ]; then
      _report "docker-present" ok
    fi
    _report "docker"
  fi

  # The one MAIN_ROOT call. CREW_DOCKER_INSTALL=off is the rollback lever back to the
  # old always-deferred behaviour, independent of CREW_DEPS (which also gates host mode).
  DOCKER_INSTALL_SCRIPT="$DEP_SCRIPTS/docker-install.sh"
  if [ "${CREW_DOCKER_INSTALL:-on}" = "off" ] || [ ! -f "$DOCKER_INSTALL_SCRIPT" ]; then
    _report "docker"
  fi

  DOCKER_OUT="$(mktemp)"
  trap 'rm -f "$DOCKER_OUT"' EXIT
  bash "$DOCKER_INSTALL_SCRIPT" --project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" \
    --timeout "$TIMEOUT" >"$DOCKER_OUT" 2>&1
  DOCKER_RC=$?
  DOCKER_CMD="$(grep -m1 '^Running: ' "$DOCKER_OUT" 2>/dev/null | sed 's/^Running: //')"
  [ -n "$DOCKER_CMD" ] || DOCKER_CMD="docker-install.sh"

  case "$DOCKER_RC" in
    0)
      mkdir -p "$(dirname "$DOCKER_MARKER")" 2>/dev/null || true
      printf '%s\n' "$DOCKER_CMD" > "$DOCKER_MARKER" 2>/dev/null || true
      _report "docker-installed $DOCKER_CMD"
      ;;
    2)
      # Nothing this mechanism can do — no compose file, no service, no supported
      # ecosystem. Same outcome as always: defer entirely to the worker.
      _report "docker"
      ;;
    4)
      # Another install is already in flight (this script, or a worker's own dep-install
      # invocation) — do not block this round waiting on it, defer instead.
      _report "docker"
      ;;
    *)
      echo "--- docker-install.sh output (tail) ---" >&2
      tail -n 20 "$DOCKER_OUT" >&2
      echo "--- end ---" >&2
      _report "docker-failed $DOCKER_CMD (exit $DOCKER_RC)"
      ;;
  esac
fi

# ─── 5. install ──────────────────────────────────────────────────────────────
# Capped, because an install that hangs would hang the whole sprint behind it. `timeout`
# is not on every host (macOS ships none), so run uncapped rather than fail when it is
# absent — the cap is a safety net, not the contract.
TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

if [ -n "$TIMEOUT_BIN" ]; then
  "$TIMEOUT_BIN" "$TIMEOUT" bash "$DEP_SCRIPTS/host-install.sh" --project-root "$DIR" \
    >"$OUT_FILE" 2>&1
else
  bash "$DEP_SCRIPTS/host-install.sh" --project-root "$DIR" >"$OUT_FILE" 2>&1
fi
RC=$?

# host-install.sh announces what it ran ("Running: npm ci"), so the command in the DEPS:
# line is its own report of it rather than a second guess at the package manager.
CMD="$(grep -m1 '^Running: ' "$OUT_FILE" 2>/dev/null | sed 's/^Running: //')"
[ -n "$CMD" ] || CMD="host-install.sh"

case "$RC" in
  0) _report "installed $CMD" ok ;;
  2) _report "none" skip ;;
  *)
    # The verbatim tail, so whoever reads the round's log sees the package manager's own
    # words and not a paraphrase of them.
    echo "--- host-install.sh output (tail) ---" >&2
    tail -n 20 "$OUT_FILE" >&2
    echo "--- end ---" >&2
    _report "failed $CMD (exit $RC)" skip
    ;;
esac
