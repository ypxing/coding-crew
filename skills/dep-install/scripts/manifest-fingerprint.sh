#!/usr/bin/env bash
# Fingerprint a project's manifest/lockfiles so host-install.sh and docker-install.sh can
# skip a redundant install when nothing has changed since their own last successful run.
#
# Deliberately independent of gen-override.sh's own ecosystem detection: that script commits
# to a single ecosystem (first match wins) because it needs one CONTAINER_SRC/volume layout
# per service. This script has no such constraint — it just needs to know whether *any*
# recognised manifest changed, so it scans for every ecosystem's lockfile at once. That also
# makes it correct for a mixed-ecosystem monorepo (e.g. a node service and a python service
# side by side), which gen-override.sh's single-ecosystem detection does not attempt.
#
# Usage:
#   manifest-fingerprint.sh compute --project-root <dir> [--max-depth N]
#   manifest-fingerprint.sh check   --project-root <dir> --stamp <path> [--max-depth N]
#   manifest-fingerprint.sh write   --project-root <dir> --stamp <path> [--max-depth N]
#
#   compute   prints one hash covering every recognised lockfile under --project-root
#             (bounded depth, common vendor/output dirs excluded).
#   check     prints FRESH if --stamp's saved hash matches the current one, STALE otherwise
#             (including when --stamp does not exist yet). Always exits 0 — the verdict is
#             the stdout line, not the exit code.
#   write     computes the current hash and atomically writes it to --stamp.
#
# What this proves, and what it does not: a FRESH verdict means the *inputs* to install are
# unchanged — it says nothing about whether the installed output (node_modules, a docker
# named volume, etc.) is still intact. That is a deliberate scope limit, not an oversight —
# see docker-install.sh/host-install.sh's own --force flag and dep-install/SKILL.md's retry
# rule, which is the actual correctness backstop: it reacts to a real module-not-found error
# from a later command, forcing a real reinstall regardless of what this script says.
#
# Exit codes:
#   0  success (all three subcommands)
#   1  argument or filesystem error

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  compute|check|write) shift ;;
  --help|-h)
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "Error: first argument must be compute, check, or write (got: ${MODE:-<none>})" >&2
    exit 1
    ;;
esac

PROJECT_ROOT=""
STAMP=""
MAX_DEPTH=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --stamp)        STAMP="$2";        shift 2 ;;
    --max-depth)    MAX_DEPTH="$2";    shift 2 ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root is required" >&2
  exit 1
fi
if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root does not exist: $PROJECT_ROOT" >&2
  exit 1
fi
if [[ "$MODE" != "compute" && -z "$STAMP" ]]; then
  echo "Error: --stamp is required for $MODE" >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

# Every lockfile name host-install.sh's signal-file table and docker-install.sh's
# _install_cmd_for_dir already recognise — kept as plain filenames here (no command mapping
# needed, this script only hashes content) so a new ecosystem added to either of those tables
# should be added here too.
_LOCKFILE_NAMES=(
  uv.lock bun.lockb pnpm-lock.yaml package-lock.json yarn.lock poetry.lock
  go.sum go.mod requirements.txt pyproject.toml Gemfile.lock Cargo.toml
  composer.json pom.xml mix.exs
)

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    openssl dgst -sha256
  fi
}

_sha256_file() {
  _sha256 < "$1" | awk '{print $1}'
}

# _compute — one hash over every "<relative-path>:<content-hash>" pair, sorted by path so the
# result is independent of filesystem iteration order. The path is part of the hashed input,
# not just the content, so a brand-new manifest directory (a subpackage nobody has installed
# yet) changes the fingerprint even before its own lockfile content is what changed.
_compute() {
  local name_args=()
  local name
  for name in "${_LOCKFILE_NAMES[@]}"; do
    [[ ${#name_args[@]} -eq 0 ]] || name_args+=(-o)
    name_args+=(-name "$name")
  done

  local lines=()
  local f rel
  while IFS= read -r f; do
    rel="${f#"$PROJECT_ROOT"/}"
    lines+=("$rel:$(_sha256_file "$f")")
  done < <(
    find "$PROJECT_ROOT" -maxdepth "$MAX_DEPTH" \( "${name_args[@]}" \) \
      -not -path '*/node_modules/*' \
      -not -path '*/.venv/*' \
      -not -path '*/vendor/*' \
      -not -path '*/target/*' \
      -not -path '*/.git/*' \
      -not -path '*/dist/*' \
      -not -path '*/build/*' \
      2>/dev/null | sort
  )

  printf '%s\n' "${lines[@]}" | _sha256 | awk '{print $1}'
}

case "$MODE" in
  compute)
    _compute
    ;;
  check)
    CURRENT="$(_compute)"
    SAVED=""
    [[ -f "$STAMP" ]] && SAVED="$(cat "$STAMP" 2>/dev/null || true)"
    if [[ -n "$SAVED" && "$SAVED" == "$CURRENT" ]]; then
      echo "FRESH"
    else
      echo "STALE"
    fi
    ;;
  write)
    CURRENT="$(_compute)"
    mkdir -p "$(dirname "$STAMP")"
    TMP="$(mktemp "${STAMP}.XXXXXX")"
    printf '%s\n' "$CURRENT" > "$TMP"
    mv "$TMP" "$STAMP"
    ;;
esac
