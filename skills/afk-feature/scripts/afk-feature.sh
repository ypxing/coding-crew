#!/usr/bin/env bash
# afk-feature.sh — run one feature's ready-for-agent issues in order on one branch; after each coder
# run, the project's checks and a fresh read-only verifier gate it. State lives in git and the tracker.
#
# Usage: afk-feature.sh <slug> [--branch <name>] [--budget <usd>] [--open-pr]
# Env: AFK_SANDBOXED=1 (bypassPermissions, for a runner or container), AFK_HOST (progress label).
# Exits 0 when no ready issue is left (last stdout line: the PR URL or the `gh pr create` command),
# 1 on a failed precondition or the first failing step (stdout names its log).

set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "afk-feature: $*" >&2; exit 1; }

SLUG="" BRANCH="" BUDGET=5 OPEN_PR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --budget) BUDGET="${2:?--budget needs a value}"; shift 2 ;;
    --open-pr) OPEN_PR=1; shift ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$SLUG" ] || die "unexpected argument: $1"; SLUG="$1"; shift ;;
  esac
done

for t in claude gh jq node git timeout; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
# The tracker's own SLUG rule: the slug reaches argv, so nothing else gets through.
[[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid feature slug: '$SLUG'"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"
COMMON="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
CLI=""
for c in "$ROOT/.coding-crew/tracker/cli.mjs" "$COMMON/.coding-crew/tracker/cli.mjs" "$HOME/.coding-crew/tracker/cli.mjs"; do
  [ -f "$c" ] && { CLI="$c"; break; }
done
[ -n "$CLI" ] || die "tracker CLI not found (.coding-crew/tracker/cli.mjs): run install.sh"
KIND="$(node "$CLI" config | grep '^tracker=' || true)"
[ "$KIND" = tracker=github ] || die "${KIND:-tracker=unknown}: feature-issues is a GitHub-only op"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean: commit or stash first"
