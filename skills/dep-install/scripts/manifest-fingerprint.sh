#!/usr/bin/env bash
# Fingerprint a project's manifest/lockfiles so host-install.sh and docker-install.sh can
# skip a redundant install when nothing has changed since their own last successful run.
#
# Usage:
#   manifest-fingerprint.sh compute --project-root <dir> [--max-depth N]
#   manifest-fingerprint.sh check   --project-root <dir> --stamp <path> [--max-depth N]
#   manifest-fingerprint.sh write   --project-root <dir> --stamp <path> [--max-depth N]
#
#   compute   one hash over every recognised lockfile (bounded depth; vendor, output and dot-dirs skipped)
#   check     prints FRESH if --stamp's hash matches the current one, else STALE; always exits 0
#   write     atomically writes the current hash to --stamp
# FRESH means the install's inputs are unchanged, not that its output is intact: dep-install's
# --force retry on a module-not-found error is the backstop.
# Exit codes: 0 success, 1 argument or filesystem error

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

# Kept in step with host-install.sh's and docker-install.sh's lockfile tables.
_LOCKFILE_NAMES=(
  package.json uv.lock bun.lockb pnpm-lock.yaml package-lock.json yarn.lock poetry.lock
  go.sum go.mod requirements.txt requirements-dev.txt dev-requirements.txt pyproject.toml
  Gemfile Gemfile.lock Cargo.toml
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

# _compute — one hash over sorted "<relative-path>:<content-hash>" pairs. The path is hashed too, so
# a new, never-installed manifest directory changes the fingerprint.
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
      -not -path "$PROJECT_ROOT/.*/*" \
      -not -path "$PROJECT_ROOT/*/.*/*" \
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
