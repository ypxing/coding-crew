#!/usr/bin/env bash
# Ensure .env exists and generate credential config files (steps 0b-c of docker-install).
# Never reads the contents of .env* or credential files.
#
# Usage: ensure-env.sh --project-root <path> [--main-root <path>] [--credential-target <make-target>]
#
# --main-root names the shared checkout a worktree's PROJECT_ROOT was branched from. When
# given and it resolves to a different directory than PROJECT_ROOT: a real .env already at
# MAIN_ROOT is linked into PROJECT_ROOT rather than PROJECT_ROOT growing its own, independent
# .env from .env.example/empty -- a worktree that regenerated its own would silently diverge
# from whatever secrets are already in the real one. When MAIN_ROOT has no .env yet either,
# generation happens exactly once, at MAIN_ROOT, then PROJECT_ROOT is linked to it -- so no two
# worktrees of the same MAIN_ROOT ever generate their own, divergent copies.
#
# Discovered override: before falling back to the mechanical .env.example-or-empty convention,
# generation consults MAIN_ROOT/.coding-crew/dev-commands.json's "env" field (or PROJECT_ROOT's own,
# when --main-root is not given -- see _cached_env_command) -- a documented .env-bootstrap
# command discover-commands.sh / write-commands-cache.sh may have cached once per sprint,
# alongside test/lint/typecheck/install, from a CLAUDE.md/AGENTS.md/Makefile this script
# deliberately never reads itself. A missing cache, a null field, or a cached command that
# runs but never actually leaves a .env behind (or fails outright) all fall through to the
# mechanical convention unchanged -- this step never blocks, so a broken override must not
# leave a worktree with no .env at all.
#
# Exit codes:
#   0  completed (always, this step never blocks)
#   1  argument error

set -euo pipefail

PROJECT_ROOT=""
MAIN_ROOT=""
CREDENTIAL_TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)       PROJECT_ROOT="$2";       shift 2 ;;
    --main-root)          MAIN_ROOT="$2";          shift 2 ;;
    --credential-target)  CREDENTIAL_TARGET="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root is required" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: PROJECT_ROOT does not exist: $PROJECT_ROOT" >&2
  exit 1
fi

log=""

# _generate_env_at <dir> -- the mechanical cp-or-touch this script has always done, isolated
# so both the plain (no --main-root) path and the MAIN_ROOT-generation path below share it
# instead of duplicating the .env.example check.
_generate_env_at() {
  local dir="$1"
  if [[ -f "$dir/.env.example" ]]; then
    cp "$dir/.env.example" "$dir/.env"
    printf 'Created .env from .env.example'
  else
    touch "$dir/.env"
    printf 'Created empty .env'
  fi
}

# _cached_env_command <cache-root> -- the discovered "env" field from
# <cache-root>/.coding-crew/dev-commands.json, written once (bootstrap) by discover-commands.sh /
# write-commands-cache.sh alongside test/lint/typecheck/install (see that pair's own header
# comments). A documented override for a repo whose local .env bootstrap is not the
# .env.example convention _generate_env_at assumes -- e.g. a `make env` target, or a setup
# script named in CLAUDE.md/AGENTS.md. A missing cache, missing file, or a cached `null` all
# mean "nothing to override" -- the caller falls through to the mechanical convention below
# unchanged, the same way ensure-deps.sh's own _cached_install_command does for install.
_cached_env_command() {
  local cache="$1/.coding-crew/dev-commands.json"
  [[ -f "$cache" ]] || return 0
  grep -o '"env"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}

# _ensure_env_at <dir> <cache-root> -- tries the discovered env override (if any) first;
# falls back to the mechanical convention when there is none, or when running the override
# did not actually leave a .env file behind in <dir> (a broken or failing override must never
# leave this step with no .env at all -- see this script's "never blocks" contract above).
_ensure_env_at() {
  local dir="$1" cache_root="$2" cached
  cached="$(_cached_env_command "$cache_root")"
  if [[ -n "$cached" ]]; then
    if ( cd "$dir" && eval "$cached" ) >/dev/null 2>&1 && [[ -f "$dir/.env" ]]; then
      printf 'Created .env via discovered command: %s' "$cached"
      return 0
    fi
  fi
  _generate_env_at "$dir"
}

# _git_exclude_env <dir> -- makes sure a .env this script just created or linked can never be
# picked up by a worker's own `git add -A`. .env is created outside version control on
# purpose (never read, never committed), but with no .gitignore entry for it a worktree's own
# `git add -A` stages it anyway, and a symlink is worse than the plain file this used to be:
# merging that commit back into MAIN_ROOT then fails with "untracked working tree files would
# be overwritten by merge" the moment MAIN_ROOT's own real .env differs in *kind* (symlink vs
# regular file) from what the branch wants to materialise there. `.git/info/exclude` is a
# local-only ignore list: it never touches the project's own tracked .gitignore, and (unlike
# the worktree-private HEAD/index) it lives in the *shared* common git dir, so adding `.env`
# from inside one worktree already covers MAIN_ROOT and every other worktree of the same repo.
# Best-effort and silent: PROJECT_ROOT not being a git repo at all is not this script's problem.
_git_exclude_env() {
  local dir="$1" common exclude
  common=$(cd "$dir" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common" in
    /*) : ;;
    *) common="$dir/$common" ;;
  esac
  exclude="$common/info/exclude"
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  touch "$exclude" 2>/dev/null || return 0
  grep -qx '.env' "$exclude" 2>/dev/null || printf '%s\n' '.env' >> "$exclude"
}

# --- Step 0b: ensure .env exists ---
# `-f` reports false for a *dangling* symlink too, not just an absent path — e.g. a stale
# `.worktreeinclude` link whose target no longer resolves. Clear it first, or `cp` refuses
# to write through it ("not writing through dangling symlink") and `touch` would silently
# resurrect whatever the broken link used to point at instead of creating `.env` itself.
if [[ -L "$PROJECT_ROOT/.env" && ! -e "$PROJECT_ROOT/.env" ]]; then
  rm -f "$PROJECT_ROOT/.env"
fi

# A MAIN_ROOT distinct from PROJECT_ROOT is the worktree case: honor whatever is already at
# MAIN_ROOT (existing, or newly generated there) instead of ever generating independently
# inside PROJECT_ROOT. `-ef` compares resolved identity, not string equality, so the one
# MAIN_ROOT call itself (where callers commonly pass the same path for both flags) falls
# through to the plain branch below rather than linking a directory to itself.
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  if [[ -n "$MAIN_ROOT" && -d "$MAIN_ROOT" ]] && ! [[ "$MAIN_ROOT" -ef "$PROJECT_ROOT" ]]; then
    if [[ -L "$MAIN_ROOT/.env" && ! -e "$MAIN_ROOT/.env" ]]; then
      rm -f "$MAIN_ROOT/.env"
    fi
    if [[ ! -f "$MAIN_ROOT/.env" ]]; then
      gen_log="$(_ensure_env_at "$MAIN_ROOT" "$MAIN_ROOT")"
      log="$gen_log at MAIN_ROOT; linked .env"
      _git_exclude_env "$MAIN_ROOT"
    else
      log="Linked .env from MAIN_ROOT"
    fi
    ln -s "$MAIN_ROOT/.env" "$PROJECT_ROOT/.env"
    _git_exclude_env "$PROJECT_ROOT"
  else
    log="$(_ensure_env_at "$PROJECT_ROOT" "${MAIN_ROOT:-$PROJECT_ROOT}")"
    _git_exclude_env "$PROJECT_ROOT"
  fi
else
  log=".env already exists"
fi

# --- Step 0c: generate credential config files ---
if [[ -n "$CREDENTIAL_TARGET" ]]; then
  make -C "$PROJECT_ROOT" "$CREDENTIAL_TARGET"
  log="$log; ran make $CREDENTIAL_TARGET"
else
  # Fallback: expand any .tpl files that have no generated counterpart yet
  tpl_expanded=""
  while IFS= read -r tpl; do
    out="${tpl%.tpl}"
    if [[ ! -f "$out" ]]; then
      envsubst < "$tpl" > "$out"
      tpl_expanded="$tpl_expanded ${out##*/}"
    fi
  done < <(find "$PROJECT_ROOT" -maxdepth 2 -name "*.tpl" \
    \( -name ".npmrc.tpl" -o -name ".yarnrc.yml.tpl" -o -name "pip.conf.tpl" \
       -o -name ".cargo/credentials.toml.tpl" \))

  if [[ -n "$tpl_expanded" ]]; then
    log="$log; generated via envsubst:$tpl_expanded"
  fi
fi

echo "$log"
exit 0
