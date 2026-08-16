#!/usr/bin/env bash
# fake-dispatch.sh — stands in for every model dispatch in tests.
#
# Behaviour is driven by files in $CREW_FAKE_DIR:
#   <slug>.worker         the worker report to emit (default: a clean `complete`)
#   <slug>.review         the review report to emit (default: AC: all-met, no findings)
#   <slug>.nocommit       do not create a commit in the worktree
#   <slug>.exit           exit with this code instead of 0
#
# `--agent coverage-validation` stands in for the agent-less wrap-up dispatch.
# `--agent commands-discovery` stands in for the agent-less one-time command-discovery
# dispatch (see orchestrator/lib/commands.mjs) — answers with commands matching the
# Makefile fixtureRepo() always writes (test/lint/typecheck targets), so a real
# write-commands-cache.sh run on the fake answer succeeds the same way a real model's would.
# A test that needs a different answer (e.g. a discovered "install" override) can drop a
# custom response at $CREW_FAKE_DIR/commands.response — read verbatim instead of the default.
set -uo pipefail

AGENT=""; DIR=""; PROMPT_FILE=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --model) shift 2 ;;
    *) shift ;;
  esac
done

SLUG=$(basename "$OUT" | sed -E 's/\.(report|review)\.md$//')
FAKE_DIR="${CREW_FAKE_DIR:?CREW_FAKE_DIR must be set}"
mkdir -p "$(dirname "$OUT")"

if [ -f "$FAKE_DIR/$SLUG.exit" ]; then
  : > "$OUT"
  exit "$(cat "$FAKE_DIR/$SLUG.exit")"
fi

if [ "$AGENT" = "coverage-validation" ]; then
  printf '## Coverage Report\n\n✓ 1 covered · ⚠ 0 partial · ✗ 0 missing\n' > "$OUT"
  exit 0
fi

if [ "$AGENT" = "commands-discovery" ]; then
  if [ -f "$FAKE_DIR/commands.response" ]; then
    cat "$FAKE_DIR/commands.response" > "$OUT"
  else
    printf '{"test": "make test", "lint": "make lint", "typecheck": "make typecheck"}' > "$OUT"
  fi
  exit 0
fi

if [ "$AGENT" = "crew-code-reviewer" ]; then
  if [ -f "$FAKE_DIR/$SLUG.review" ]; then
    cat "$FAKE_DIR/$SLUG.review" > "$OUT"
  else
    printf '## Branch: crew/x/%s\nAC: all-met\n\nNo findings.\n' "$SLUG" > "$OUT"
  fi
  exit 0
fi

# Worker: make a real commit so the branch has content to verify and merge.
if [ ! -f "$FAKE_DIR/$SLUG.nocommit" ]; then
  (
    cd "$DIR" || exit 1
    mkdir -p src
    echo "// $SLUG" >> "src/$SLUG.txt"
    git add -A >/dev/null 2>&1
    git -c user.email=fake@test -c user.name=fake commit -q -m "feat: $SLUG" >/dev/null 2>&1
  )
fi

if [ -f "$FAKE_DIR/$SLUG.worker" ]; then
  cat "$FAKE_DIR/$SLUG.worker" > "$OUT"
else
  cat > "$OUT" <<EOF
## Issue: $SLUG
Status: complete

\`\`\`json
{"status":"complete","branch":"$(cd "$DIR" && git rev-parse --abbrev-ref HEAD)","working_directory":"$DIR","checks":{"test":"pass","lint":"pass","typecheck":"pass"},"progress":"","notes":"done"}
\`\`\`
EOF
fi
exit 0
