#!/usr/bin/env bash
# review-context.sh — decide which review references apply to this repo.
#
# The reviewer's framework checklists are conditional: a React block is noise in a Go repo and a
# backend block is noise in a static site. Which ones apply is a mechanical question about signal
# files, so it is answered by this script instead of by a paragraph asking the model to guess.
#
# Usage: review-context.sh [--root <dir>]
# Output (stable, line-oriented):
#   STACK: <space-separated tags, or "generic">
#   REFERENCE: <path>            (repeated; absolute paths, existing files only)
#   REFERENCE: none              (only when no reference file could be resolved)
# Always exits 0 — a missing reference must never fail a review.

set -uo pipefail

ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
REF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../references" 2>/dev/null && pwd || true)"

# List candidate files cheaply: tracked files when this is a git repo, else a bounded find.
list_files() {
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$ROOT" ls-files 2>/dev/null
  else
    (cd "$ROOT" && find . -type d -name node_modules -prune -o -type f -print 2>/dev/null | sed 's|^\./||')
  fi
}

# grep a manifest for framework names without depending on jq at review time.
manifest_has() {
  local file="$1" pattern="$2"
  [[ -f "$ROOT/$file" ]] || return 1
  grep -Eiq "$pattern" "$ROOT/$file"
}

FILES="$(list_files)"
has_ext() { printf '%s\n' "$FILES" | grep -Eq "\.($1)$"; }

STACK=()

# ── React / Next.js ───────────────────────────────────────────────────────────
REACT=0
if manifest_has package.json '"(react|next|react-dom|react-native)"' || has_ext 'tsx|jsx'; then
  REACT=1
fi

# ── Backend / service ─────────────────────────────────────────────────────────
BACKEND=0
if manifest_has package.json '"(express|fastify|koa|@nestjs/[a-z]+|@hapi/hapi|hapi|apollo-server[a-z-]*|trpc|@trpc/[a-z]+|prisma|@prisma/client|mongoose|sequelize|typeorm|knex|pg|mysql2?|redis|ioredis)"' \
  || manifest_has requirements.txt '(flask|django|fastapi|starlette|sqlalchemy|psycopg2?|aiohttp|tornado)' \
  || manifest_has pyproject.toml '(flask|django|fastapi|starlette|sqlalchemy|psycopg2?|aiohttp|tornado)' \
  || manifest_has go.mod '(gin-gonic|labstack/echo|gofiber|go-chi|gorilla/mux|gorm\.io|jackc/pgx)' \
  || manifest_has Gemfile '(rails|sinatra|sequel|pg|activerecord)' \
  || manifest_has composer.json '(laravel|symfony|slim/slim)'; then
  BACKEND=1
fi

# ── Web / HTTP surface ────────────────────────────────────────────────────────
WEB=0
if [[ "$REACT" -eq 1 || "$BACKEND" -eq 1 ]] \
  || has_ext 'html|htm|vue|svelte|ejs|hbs|erb|jinja2|twig|astro'; then
  WEB=1
fi

REFS=()
add_ref() {
  local name="$1"
  [[ -n "$REF_DIR" && -f "$REF_DIR/$name" ]] || return 0
  REFS+=("$REF_DIR/$name")
}

# quality.md is language-agnostic and always applies; the rest are conditional.
add_ref quality.md
[[ "$WEB" -eq 1 ]] && { STACK+=("web"); add_ref web-security.md; }
[[ "$REACT" -eq 1 ]] && { STACK+=("react"); add_ref react.md; }
[[ "$BACKEND" -eq 1 ]] && { STACK+=("backend"); add_ref backend.md; }

if [[ "${#STACK[@]}" -eq 0 ]]; then
  echo "STACK: generic"
else
  echo "STACK: ${STACK[*]}"
fi

if [[ "${#REFS[@]}" -eq 0 ]]; then
  echo "REFERENCE: none"
else
  for r in "${REFS[@]}"; do echo "REFERENCE: $r"; done
fi

exit 0
