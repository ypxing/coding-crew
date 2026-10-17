#!/usr/bin/env bash
# Ensure .env exists and generate credential config files (steps 0b-c of docker-install).
# Never reads the contents of .env* or credential files. Never blocks: exit 0, or 1 on an argument error.
# Usage: ensure-env.sh --project-root <path>
# A missing .env is generated in PROJECT_ROOT: the dev commands file's "env" command, else
# .env.example-or-empty; a broken command falls through. Then the file's "registry_auth" command runs.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SELF_DIR/commands-file.sh"

PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)   PROJECT_ROOT="$2";   shift 2 ;;
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

# _ensure_env_at <dir> — the discovered command counts only if it actually leaves a .env behind.
_ensure_env_at() {
  local dir="$1" cached
  cached="$(commands_field "$(commands_file "$dir")" env)"
  if [[ -n "$cached" ]]; then
    if ( cd "$dir" && eval "$cached" ) >/dev/null 2>&1 && [[ -f "$dir/.env" ]]; then
      printf 'Created .env via discovered command: %s' "$cached"
      return 0
    fi
  fi
  _generate_env_at "$dir"
}

# _git_exclude_env <dir> — keeps a generated .env out of a `git add -A`. info/exclude is local-only
# and shared by every worktree. Best-effort.
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

if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  log="$(_ensure_env_at "$PROJECT_ROOT")"
  _git_exclude_env "$PROJECT_ROOT"
else
  log=".env already exists"
fi

# REGISTRY_AUTH is a full command (e.g. "make _registry"). One that runs docker itself is skipped
# (no docker to nest into); a skip or a failure falls through to .tpl expansion.
REGISTRY_AUTH="$(commands_field "$(commands_file "$PROJECT_ROOT")" registry_auth)"
ran_registry_auth=0
if [[ -n "$REGISTRY_AUTH" ]]; then
  if bash "$SELF_DIR/detect-docker-nesting.sh" --dir "$PROJECT_ROOT" --cmd "$REGISTRY_AUTH"; then
    log="$log; discovered registry_auth '$REGISTRY_AUTH' already invokes docker -- skipping to avoid nesting docker-in-docker"
  elif ( cd "$PROJECT_ROOT" && eval "$REGISTRY_AUTH" ) >/dev/null 2>&1; then
    log="$log; ran discovered registry_auth: $REGISTRY_AUTH"
    ran_registry_auth=1
  else
    log="$log; discovered registry_auth '$REGISTRY_AUTH' failed, falling back to template expansion"
  fi
fi

if [[ "$ran_registry_auth" -eq 0 ]]; then
  tpl_expanded=""
  while IFS= read -r tpl; do
    out="${tpl%.tpl}"
    if [[ ! -f "$out" ]]; then
      envsubst < "$tpl" > "$out"
      tpl_expanded="$tpl_expanded ${out##*/}"
    fi
  done < <(find "$PROJECT_ROOT" -maxdepth 2 -name "*.tpl" \
    \( -name ".npmrc.tpl" -o -name ".yarnrc.yml.tpl" -o -name "pip.conf.tpl" \))

  if [[ -n "$tpl_expanded" ]]; then
    log="$log; generated via envsubst:$tpl_expanded"
  fi
fi

echo "$log"
exit 0
