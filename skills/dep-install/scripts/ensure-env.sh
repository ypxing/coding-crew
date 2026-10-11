#!/usr/bin/env bash
# Ensure .env exists and generate credential config files (steps 0b-c of docker-install).
# Never reads the contents of .env* or credential files. Never blocks: exit 0, or 1 on an argument error.
# Usage: ensure-env.sh --project-root <path> [--main-root <path>] [--credential-target <command>]
# A worktree links MAIN_ROOT's .env (generated there once if missing), so worktrees never diverge.
# Generation tries dev-commands.json's "env" command, then a Makefile env target, then
# .env.example-or-empty; a broken override falls through.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

_cached_env_command() {
  local cache="$1/.coding-crew/dev-commands.json"
  [[ -f "$cache" ]] || return 0
  grep -o '"env"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache" 2>/dev/null \
    | head -1 \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/'
}

# _makefile_env_command <dir> — a non-docker Makefile env target, in case command discovery missed it.
_makefile_env_command() {
  local dir="$1" target recipe
  [[ -f "$dir/Makefile" ]] || return 0
  for target in env .env dotenv setup-env; do
    # Non-empty output, not exit status, means the target exists: some GNU Make builds (3.81) run a
    # recipe containing "make" even under -n, so a daemon-less docker failure would read as no target.
    recipe=$(cd "$dir" && make -n "$target" 2>/dev/null || true)
    [[ -n "$recipe" ]] || continue
    if grep -qE 'docker (compose|run|exec)' <<<"$recipe"; then
      continue
    fi
    printf 'make %s' "$target"
    return 0
  done
  return 0
}

# _ensure_env_at <dir> <cache-root> — a tier counts only if it actually leaves a .env behind.
_ensure_env_at() {
  local dir="$1" cache_root="$2" cached guessed
  cached="$(_cached_env_command "$cache_root")"
  if [[ -n "$cached" ]]; then
    if ( cd "$dir" && eval "$cached" ) >/dev/null 2>&1 && [[ -f "$dir/.env" ]]; then
      printf 'Created .env via discovered command: %s' "$cached"
      return 0
    fi
  fi
  guessed="$(_makefile_env_command "$dir")"
  if [[ -n "$guessed" ]]; then
    if ( cd "$dir" && eval "$guessed" ) >/dev/null 2>&1 && [[ -f "$dir/.env" ]]; then
      printf 'Created .env via Makefile target: %s' "$guessed"
      return 0
    fi
  fi
  _generate_env_at "$dir"
}

# _git_exclude_env <dir> — keeps a .env out of a worker's `git add -A`: a committed symlink breaks the
# merge into MAIN_ROOT. info/exclude is local-only and shared by every worktree. Best-effort.
_git_exclude_env() {
  local dir="$1" common exclude
  common=$(cd "$dir" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  case "$common" in
    /*|[A-Za-z]:*) : ;;
    *) common="$dir/$common" ;;
  esac
  exclude="$common/info/exclude"
  mkdir -p "$(dirname "$exclude")" 2>/dev/null || return 0
  touch "$exclude" 2>/dev/null || return 0
  grep -qx '.env' "$exclude" 2>/dev/null || printf '%s\n' '.env' >> "$exclude"
}

# `-f` is false for a dangling symlink too (a stale .worktreeinclude link): clear it, or `cp`
# refuses to write through it and `touch` recreates its old target.
if [[ -L "$PROJECT_ROOT/.env" && ! -e "$PROJECT_ROOT/.env" ]]; then
  rm -f "$PROJECT_ROOT/.env"
fi

# A distinct MAIN_ROOT is the worktree case: reuse or generate MAIN_ROOT's .env. Compared by resolved
# path, not `-ef` (unreliable under MSYS's NTFS emulation).
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  if [[ -n "$MAIN_ROOT" && -d "$MAIN_ROOT" ]] && [[ "$(cd "$MAIN_ROOT" && pwd -P)" != "$(cd "$PROJECT_ROOT" && pwd -P)" ]]; then
    if [[ -L "$MAIN_ROOT/.env" && ! -e "$MAIN_ROOT/.env" ]]; then
      rm -f "$MAIN_ROOT/.env"
    fi
    if [[ ! -f "$MAIN_ROOT/.env" ]]; then
      gen_log="$(_ensure_env_at "$MAIN_ROOT" "$MAIN_ROOT")"
      log="$gen_log at MAIN_ROOT"
      _git_exclude_env "$MAIN_ROOT"
    else
      log="MAIN_ROOT's .env"
    fi
    ln -s "$MAIN_ROOT/.env" "$PROJECT_ROOT/.env" 2>/dev/null || true
    if [[ -L "$PROJECT_ROOT/.env" ]]; then
      log="$log; linked into PROJECT_ROOT"
    else
      # No symlink privilege (Windows without Developer Mode): MSYS may fake one, so force a clean copy.
      rm -f "$PROJECT_ROOT/.env"
      cp "$MAIN_ROOT/.env" "$PROJECT_ROOT/.env"
      log="$log; copied into PROJECT_ROOT (symlink unavailable)"
    fi
    _git_exclude_env "$PROJECT_ROOT"
  else
    log="$(_ensure_env_at "$PROJECT_ROOT" "${MAIN_ROOT:-$PROJECT_ROOT}")"
    _git_exclude_env "$PROJECT_ROOT"
  fi
else
  log=".env already exists"
fi

# CREDENTIAL_TARGET is a full command (e.g. "make _registry"). One that runs docker itself is skipped
# (no docker to nest into); a skip or a failure falls through to .tpl expansion.
ran_credential_target=0
if [[ -n "$CREDENTIAL_TARGET" ]]; then
  if bash "$SELF_DIR/detect-docker-nesting.sh" --dir "$PROJECT_ROOT" --cmd "$CREDENTIAL_TARGET"; then
    log="$log; discovered credential_target '$CREDENTIAL_TARGET' already invokes docker -- skipping to avoid nesting docker-in-docker"
  elif ( cd "$PROJECT_ROOT" && eval "$CREDENTIAL_TARGET" ) >/dev/null 2>&1; then
    log="$log; ran discovered credential_target: $CREDENTIAL_TARGET"
    ran_credential_target=1
  else
    log="$log; discovered credential_target '$CREDENTIAL_TARGET' failed, falling back to template expansion"
  fi
fi

if [[ "$ran_credential_target" -eq 0 ]]; then
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
