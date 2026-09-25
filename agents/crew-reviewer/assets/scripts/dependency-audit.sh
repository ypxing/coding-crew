#!/usr/bin/env bash
# dependency-audit.sh — run the dependency audit for whatever package managers this repo uses.
#
# Was a six-row table in the reviewer protocol that the model executed by hand, once per session.
# Detection and invocation are mechanical, so they live here; judging the output is the review.
#
# Usage: dependency-audit.sh [--root <dir>]
# Output: one `### <manager>` block per signal file found, each followed by verbatim tool output,
#         or `NOT RUN: <tool> not found`. `NO MANIFEST FOUND` when nothing matched.
# Always exits 0 — a vulnerable dependency is a finding, not a failed review, and a missing audit
# tool must not abort one either.

set -uo pipefail

ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done
[[ -n "$ROOT" ]] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

FOUND=0

run_audit() {
  local label="$1" tool="$2"
  shift 2
  FOUND=1
  echo "### $label"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "NOT RUN: $tool not found"
    echo
    return 0
  fi
  # Audit tools exit non-zero when they find something; that output is the point.
  ( cd "$ROOT" && "$@" 2>&1 ) || true
  echo
}

[[ -f "$ROOT/pnpm-lock.yaml" ]] && run_audit "pnpm audit" pnpm pnpm audit --audit-level=high
[[ -f "$ROOT/yarn.lock" ]] && run_audit "yarn audit" yarn yarn audit --level high
[[ -f "$ROOT/package-lock.json" ]] && run_audit "npm audit" npm npm audit --audit-level=high
[[ -f "$ROOT/go.sum" ]] && run_audit "govulncheck" govulncheck govulncheck ./...
if [[ -f "$ROOT/requirements.txt" || -f "$ROOT/pyproject.toml" ]]; then
  run_audit "pip-audit" pip-audit pip-audit
fi
[[ -f "$ROOT/Gemfile.lock" ]] && run_audit "bundle audit" bundle bundle audit check --update

if [[ "$FOUND" -eq 0 ]]; then
  echo "NO MANIFEST FOUND: no pnpm-lock.yaml, yarn.lock, package-lock.json, go.sum, requirements.txt, pyproject.toml or Gemfile.lock at $ROOT"
fi

exit 0
