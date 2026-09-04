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
#   decision to dep-install's own detect-mode.sh / host-install.sh, or — when one is cached —
#   to command discovery's own "install" answer (see step 1b, `_cached_install_command`),
#   which is the one place a documented CLAUDE.md/AGENTS.md/Makefile override reaches this
#   script without it ever reading those files itself. Generating the docker override
#   (compose file, volumes) is still judgement docker-install.sh owns; forwarding the cached
#   override as `--install-cmd` is not — it is the same mechanical hand-off step 5 does on
#   the host path.
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

# _debug_log_path — where a failed command's full output is persisted.
#
# Only the one DEPS: line above survives into whatever the caller does with this
# script's output (the orchestrator's own log, the trace log): stderr — the tail printed
# next to each failure below — is captured by the caller and thrown away (see
# Sprint.installDeps / runWorker in orchestrator/lib). Without a file on disk, "docker-failed"
# or "failed npm ci (exit 1)" is all that is ever left to debug from. Reusing the per-issue
# marker path when one exists keeps the log beside the .ok/.skip marker it explains;
# otherwise it falls back to the target directory's own .scratch, so a standalone run
# (no sprint, no --slug) still leaves something on disk to point at.
_debug_log_path() {
  if [ -n "$MARKER" ]; then
    printf '%s' "$MARKER.log"
  else
    printf '%s' "$DIR/.scratch/deps-install.log"
  fi
}

# _persist_log <dest> <source-file> — best-effort copy, mkdir -p first. Never fails the
# caller: a log that could not be written is no worse than the tail already on stderr.
_persist_log() {
  local dest="$1" src="$2"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 0
  cp "$src" "$dest" 2>/dev/null || true
}

# ─── 1. escape hatch ─────────────────────────────────────────────────────────
# Mirrors CREW_RECEIPTS=off: an operator debugging the pipeline can take one
# mechanism out of it without editing the orchestrator.
if [ "${CREW_DEPS:-on}" = "off" ]; then
  _report "skipped"
fi

# ─── 1b. the discovered install override ──────────────────────────────
# $MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json's "install" field — cached once
# (bootstrap) by discover-commands.sh / write-commands-cache.sh, before this script's own
# MAIN_ROOT call, from a documented CLAUDE.md/AGENTS.md/Makefile override this script would
# otherwise never see: it deliberately never reads those files itself (see the top-of-file
# comment). Resolved this early
# — ahead of the presence guard at step 3 — because an explicit override also stands in for that
# guard's manifest check: a source that documents its own install command has a dependency step
# whether or not this script recognises the ecosystem's usual manifest file.
#
# A missing cache, a missing file, or a cached `null` all mean the same thing here: nothing to
# override, fall through to the mechanical detection below unchanged.
MAIN_ROOT_EFFECTIVE="${MAIN_ROOT:-}"
if [ -z "$MAIN_ROOT_EFFECTIVE" ]; then
  MAIN_ROOT_EFFECTIVE="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || echo "$DIR")"
fi
_cached_install_command() {
  local cache="$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json"
  [ -f "$cache" ] || return 0
  grep -o '"install"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}
CACHED_INSTALL="$(_cached_install_command)"

# _cached_credential_target — the same cache's "credential_target" field: the full command (if
# any) that runs the Makefile target whose recipe generates package-manager credential config
# files. Forwarded to docker-install.sh's own --credential-target flag (step 4, docker mode
# only — the host path has no credential-file generation step of its own to override). A
# missing cache, missing field, or cached `null` all mean "no override", the same as install:
# this script never scans Makefile comments for it itself, docker-install.sh keeps calling
# ensure-env.sh with no --credential-target, and ensure-env.sh's own template-expansion
# fallback still applies.
_cached_credential_target() {
  local cache="$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json"
  [ -f "$cache" ] || return 0
  grep -o '"credential_target"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}
CACHED_CREDENTIAL_TARGET="$(_cached_credential_target)"

# _merge_mode_cache <docker|host> — writes detect-mode.sh's verdict into the same committed
# cache, alongside install/env/credential_target, so it is trusted indefinitely instead of
# re-derived every sprint. Mirrors write-commands-cache.sh's own field-preserving technique
# (grep out each known field's raw token, rebuild the JSON body, atomic mktemp+mv) rather than
# calling that script directly: it has no path reachable from here — unlike dep-install's
# scripts, it gets no platform-neutral install copy, only one buried in each of crew-afk's and
# solve-issue's own per-platform skill directories.
_merge_mode_cache() {
  local mode_val="$1" cache="$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json" old=""
  # Mirrors write-commands-cache.sh's FIELDS (test lint typecheck install env credential_target)
  # plus mode — keep this list in sync if a field is ever added/removed there.
  local fields=(test lint typecheck install env credential_target)
  [ -f "$cache" ] && old="$(cat "$cache" 2>/dev/null || true)"
  local body="" f v
  for f in "${fields[@]}"; do
    v="$(printf '%s' "$old" | grep -o "\"$f\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" \
      | head -1 | sed -E "s/\"$f\"[[:space:]]*:[[:space:]]*//")"
    [ -n "$v" ] || continue
    [ -n "$body" ] && body="$body, "
    body="$body\"$f\": $v"
  done
  [ -n "$body" ] && body="$body, "
  mkdir -p "$MAIN_ROOT_EFFECTIVE/.coding-crew" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp "$MAIN_ROOT_EFFECTIVE/.coding-crew/dev-commands.json.XXXXXX" 2>/dev/null)" || return 0
  printf '{%s"mode": "%s"}\n' "$body" "$mode_val" > "$tmp"
  mv "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
}

# ─── 2. resolve dep-install's scripts ────────────────────────────────────────
# No install logic lives here. host-install.sh stays the only place that knows package
# managers, so this only has to find it — and it must find it without knowing which of the
# four platform skill directories a consuming repo installed, which is why install.sh also
# ships one platform-neutral copy at .coding-crew/dep-install/scripts.
#
# Resolved ahead of the presence guard (used to be step 3) so the MAIN_ROOT check below
# can run detect-mode.sh before that guard gets a chance to fire.
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

# ─── 2b. main-root docker check, ahead of the presence guard ─────────────────
# The one MAIN_ROOT call's job (see step 4) is to warm the shared *docker volume* once —
# a store completely separate from whatever host-side dep dir might already sit in
# MAIN_ROOT (predating .worktreeinclude excluding it, or a contributor's own local
# install). The presence guard below exists to say "nothing to do", which is true on the
# host path but not here: a host-side node_modules being present says nothing about
# whether the docker volume — and docker-compose.override.yml — have ever been generated.
# Without this check, that stale host copy makes the guard return `present` and the
# MAIN_ROOT call never reaches step 4 at all, so the override is never written and every
# worktree this sprint is left reporting bare `docker` (deferred) instead of
# `docker-present`.
#
# Worktree calls (--slug set) are unaffected — there, an inherited dep dir via
# .worktreeinclude genuinely means there is nothing to do, so the guard stays first.
MAIN_ROOT_MODE=""
SKIP_PRESENCE_GUARD=0
if [ -z "$SLUG" ]; then
  MAIN_ROOT_MODE="$(bash "$DEP_SCRIPTS/detect-mode.sh" --project-root "$DIR" 2>/dev/null || echo USE_HOST)"
  [ "$MAIN_ROOT_MODE" = "USE_DOCKER" ] && SKIP_PRESENCE_GUARD=1
fi

# ─── 3. the presence guard ───────────────────────────────────────────────────
# The real guard, and the reason a resumed sprint and a .worktreeinclude repo cost
# nothing: if the ecosystem's dep dir is already in $DIR there is nothing to do, and no
# marker, no round counter and no cache is consulted to establish that.
#
# One row per ecosystem: "<dep dir>:<manifest> <manifest> …". A manifest with no dep dir
# means an install is worth attempting; no manifest at all means this repo has no
# dependency step.
if [ "$SKIP_PRESENCE_GUARD" -eq 0 ]; then
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

# An explicit, documented install override (step 1b) means there is a dependency step even
# when no ecosystem's usual manifest file is present — a custom bootstrap script has no
# lockfile for this heuristic to find, which is exactly the case the override exists for.
if [ "$HAS_MANIFEST" -eq 0 ] && [ -n "$CACHED_INSTALL" ]; then
  HAS_MANIFEST=1
fi

if [ "$HAS_MANIFEST" -eq 0 ]; then
  _report "none" skip
fi

# ─── 3b. the marker cache ─────────────────────────────────────────────────────
# `none` and `failed` are the two outcomes that would otherwise be re-probed every round
# for the same worktree — one of them runs a full install command to learn nothing new.
# Cache them. The guard above has already run, so a worktree that has since acquired its
# deps reports `present` regardless of what this file says.
if [ -n "$MARKER" ] && [ -f "$MARKER.skip" ]; then
  _report "$(cat "$MARKER.skip" 2>/dev/null || echo none)"
fi
fi  # SKIP_PRESENCE_GUARD

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
# real work"; a worktree call only ever checks whether that already happened. Already
# resolved once, at step 1b.
DOCKER_MARKER="$MAIN_ROOT_EFFECTIVE/.scratch/docker-install.done"

# Reuse the MAIN_ROOT verdict from step 2b when this is that call, instead of running
# detect-mode.sh a second time for the same directory.
if [ -n "$MAIN_ROOT_MODE" ]; then
  MODE="$MAIN_ROOT_MODE"
else
  MODE="$(bash "$DEP_SCRIPTS/detect-mode.sh" --project-root "$DIR" 2>/dev/null || echo USE_HOST)"
fi
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

  # Also merge it into .coding-crew/dev-commands.json's "mode" field, written once here (the
  # MAIN_ROOT call, before any worktree exists — nothing to race with) and read by
  # detect-mode.sh ahead of its own Makefile heuristic. The git-config write above can still
  # silently lose a lock race against a sibling issue's own ensure-deps.sh call once
  # worktrees start running concurrently, and it only helps a reader that shares this
  # checkout's git config in the first place — a worker's independent up-front check may
  # resolve a completely different install of dep-install (a different platform's skill copy,
  # a stale global one) and re-derive its own answer from scratch. A committed cache at a
  # fixed, well-known path is something any copy of detect-mode.sh can agree on regardless of
  # which one is running — and, unlike a .scratch file, it survives to the next sprint too.
  if [ -z "$SLUG" ]; then
    _merge_mode_cache docker

    # Generate the override as soon as the cache says docker, independent of whatever
    # docker-install.sh decides below — it can exit 2 for reasons that have nothing to do
    # with whether an override CAN be generated (no lockfile it recognises in a manifest
    # dir, an --install-cmd override that itself invokes docker), which would otherwise
    # leave the cache and Step 0's fast path (dep-install/SKILL.md) disagreeing about
    # whether docker-compose.override.yml exists. A real compose-file/ecosystem failure
    # (no compose file, no supported ecosystem) fails this the same way it would fail
    # docker-install.sh's own attempt, so this is not a second guess — just an earlier one.
    [ -f "$DEP_SCRIPTS/gen-override.sh" ] &&
      bash "$DEP_SCRIPTS/gen-override.sh" --project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" >/dev/null 2>&1 || true
  fi

  if [ -n "$SLUG" ]; then
    # A worktree call: the shared install already happened or it did not. Either way
    # there is nothing for a worktree to install into a volume every other worktree
    # already shares — a branch that adds its own new dependency is exactly the
    # "trivial impact" case dep-install's own retry rule already covers reactively
    # (module-not-found → re-run install), so it is left there rather than duplicated.
    if [ -f "$DOCKER_MARKER" ]; then
      # docker-install.md tells a worker that lands on this fast path to skip straight to
      # "run install" — it never calls gen-override.sh for this worktree, which is the one
      # place the worktree's own docker-compose.override.yml symlink gets created. Every
      # mechanical caller (verify-worktree.sh, docker-install.sh) always passes
      # $MAIN_ROOT/docker-compose.override.yml explicitly via -f and never needed that
      # symlink, but a bare `docker compose run` a worker or human types by hand does — so
      # create it here instead of leaving every fast-path worktree without one.
      [ -f "$DEP_SCRIPTS/gen-override.sh" ] &&
        bash "$DEP_SCRIPTS/gen-override.sh" --link-only --project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" >/dev/null 2>&1 || true
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
  DOCKER_ARGS=(--project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" --timeout "$TIMEOUT")
  # Forward the same discovered override step 5 would otherwise use on the host path —
  # without this, docker-install.sh falls back to its own lockfile table and silently runs
  # a different command than the one a CLAUDE.md/AGENTS.md/Makefile documents.
  [ -n "$CACHED_INSTALL" ] && DOCKER_ARGS+=(--install-cmd "$CACHED_INSTALL")
  # Forward the same discovered credential-target override step 0 would otherwise leave to
  # docker-install.md's own Makefile-comment scan — without this, a repo whose docker install
  # needs a generated .npmrc/pip.conf/etc. silently gets ensure-env.sh's template-only
  # fallback instead of the credential-generating target a prior discovery already found.
  [ -n "$CACHED_CREDENTIAL_TARGET" ] && DOCKER_ARGS+=(--credential-target "$CACHED_CREDENTIAL_TARGET")
  bash "$DOCKER_INSTALL_SCRIPT" "${DOCKER_ARGS[@]}" >"$DOCKER_OUT" 2>&1
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
      DOCKER_LOG="$MAIN_ROOT_EFFECTIVE/.scratch/docker-install.log"
      _persist_log "$DOCKER_LOG" "$DOCKER_OUT"
      echo "--- docker-install.sh output (tail) ---" >&2
      tail -n 20 "$DOCKER_OUT" >&2
      echo "--- end; full output saved to $DOCKER_LOG ---" >&2
      _report "docker-failed $DOCKER_CMD (exit $DOCKER_RC) (see $DOCKER_LOG)"
      ;;
  esac
elif [ -z "$SLUG" ]; then
  # Host gets the same "trusted indefinitely" cache install/env/credential_target and the
  # docker branch above already get — without this, every worktree/issue this sprint re-runs
  # detect-mode.sh's Makefile dry-run loop (up to 9 targets) to reach the same host answer
  # already settled at this MAIN_ROOT call.
  _merge_mode_cache host
fi

# ─── 5. install ──────────────────────────────────────────────────────────────
# Capped, because an install that hangs would hang the whole sprint behind it. `timeout`
# is not on every host (macOS ships none), so run uncapped rather than fail when it is
# absent — the cap is a safety net, not the contract.
TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

# $CACHED_INSTALL was already resolved at step 1b, from the same command-discovery cache the
# presence guard's manifest override (step 3) already consulted.
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

if [ -n "$CACHED_INSTALL" ]; then
  # Run in $DIR, not $MAIN_ROOT_EFFECTIVE — this call installs into whichever directory
  # was passed as --dir (a worktree, or the main root itself), the same target
  # host-install.sh would have used.
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$TIMEOUT" bash -c 'cd "$1" && eval "$2"' _ "$DIR" "$CACHED_INSTALL" \
      >"$OUT_FILE" 2>&1
  else
    bash -c 'cd "$1" && eval "$2"' _ "$DIR" "$CACHED_INSTALL" >"$OUT_FILE" 2>&1
  fi
  RC=$?
  CMD="$CACHED_INSTALL"

  if [ "$RC" -eq 0 ]; then
    _report "installed $CMD" ok
  fi
  # A discovered command that fails is a real failure, not host-install.sh's "no install
  # method found" (exit 2) — that signal only means something to the fallback path below,
  # so any non-zero exit here is reported as failed rather than reinterpreted as `none`.
  DEPS_LOG="$(_debug_log_path)"
  _persist_log "$DEPS_LOG" "$OUT_FILE"
  echo "--- discovered install command output (tail) ---" >&2
  tail -n 20 "$OUT_FILE" >&2
  echo "--- end; full output saved to $DEPS_LOG ---" >&2
  _report "failed $CMD (exit $RC) (see $DEPS_LOG)" skip
fi

if [ -n "$TIMEOUT_BIN" ]; then
  "$TIMEOUT_BIN" "$TIMEOUT" bash "$DEP_SCRIPTS/host-install.sh" --project-root "$DIR" \
    --main-root "$MAIN_ROOT_EFFECTIVE" >"$OUT_FILE" 2>&1
else
  bash "$DEP_SCRIPTS/host-install.sh" --project-root "$DIR" --main-root "$MAIN_ROOT_EFFECTIVE" \
    >"$OUT_FILE" 2>&1
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
    DEPS_LOG="$(_debug_log_path)"
    _persist_log "$DEPS_LOG" "$OUT_FILE"
    echo "--- host-install.sh output (tail) ---" >&2
    tail -n 20 "$OUT_FILE" >&2
    echo "--- end; full output saved to $DEPS_LOG ---" >&2
    _report "failed $CMD (exit $RC) (see $DEPS_LOG)" skip
    ;;
esac
