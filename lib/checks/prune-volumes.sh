#!/usr/bin/env bash
# Record this checkout's dependency volumes, and remove the ones no live checkout of the repo still names.
#
# Usage:
#   bash scripts/prune-volumes.sh --project-root <path>
#
# A volume is live while some checkout's crew-compose.override.yml names it: the main checkout's in the
# common git dir, a linked worktree's in <common>/worktrees/<id>/, which `git worktree remove` deletes.
# So a removed worktree's volumes, and a checkout's volumes from before its lockfile changed, are not.
# <common>/crew-volumes lists every volume an override has named: only those are this repo's to remove.
# A volume a container has mounted fails to go and stays listed for the next call.
# Exit codes: 0 always (no docker, no override: nothing to do)

set -uo pipefail

PROJECT_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
    *) echo "Error: unknown argument: $1" >&2; exit 0 ;;
  esac
done

common="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
gitdir="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || exit 0
ledger="$common/crew-volumes"

names() { sed -nE 's/^    name: (wt_[^[:space:]]+)$/\1/p' "$@" 2>/dev/null; }

own="$gitdir/crew-compose.override.yml"
[ -f "$own" ] || exit 0
touch "$ledger"
names "$own" | while IFS= read -r v; do grep -qxF "$v" "$ledger" || echo "$v" >> "$ledger"; done

command -v docker >/dev/null 2>&1 || exit 0
live="$(names "$common/crew-compose.override.yml" "$common"/worktrees/*/crew-compose.override.yml)"
keep="$(mktemp "$ledger.XXXXXX")" || exit 0
while IFS= read -r v; do
  if grep -qxF "$v" <<< "$live" || ! docker volume rm -f "$v" >/dev/null 2>&1; then echo "$v"; fi
done < "$ledger" > "$keep"
mv "$keep" "$ledger"
exit 0
