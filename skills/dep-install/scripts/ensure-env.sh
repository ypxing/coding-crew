#!/usr/bin/env bash
# Ensure .env exists and generate credential config files (steps 0b-c of docker-install).
# Never reads the contents of .env* or credential files.
#
# Usage: ensure-env.sh --project-root <path> [--credential-target <make-target>]
# Exit codes:
#   0  completed (always, this step never blocks)
#   1  argument error

set -euo pipefail

PROJECT_ROOT=""
CREDENTIAL_TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)       PROJECT_ROOT="$2";       shift 2 ;;
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

# --- Step 0b: ensure .env exists ---
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  if [[ -f "$PROJECT_ROOT/.env.example" ]]; then
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    log="Created .env from .env.example"
  else
    touch "$PROJECT_ROOT/.env"
    log="Created empty .env"
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
