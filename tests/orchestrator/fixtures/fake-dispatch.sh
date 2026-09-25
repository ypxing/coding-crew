#!/usr/bin/env bash
# fake-dispatch.sh — stands in for every model dispatch in tests.
#
# Behaviour is driven by files in $CREW_FAKE_DIR:
#   <slug>.worker         the worker report to emit (default: a clean `complete`)
#   <slug>.review         the review report to emit (default: verdict all-met, no findings)
#   <slug>.review-once    the review report is empty (review-not-run) on the *first* call
#                         for this slug, then verdict all-met on every call after — simulates a
#                         review dispatch that failed transiently and succeeds on retry.
#                         Mutually exclusive with <slug>.review; a per-slug call counter is
#                         kept at <slug>.review-once.calls next to it.
#   <slug>.review-once-garbled   same shape as <slug>.review-once, except the first call's
#                         report is *non-empty* prose with no fenced json at all — a herdr
#                         capture that read back a truncated fragment rather than a truly
#                         empty pane. report.mjs's sidecar-only policy treats this identically
#                         to a truly empty first call (neither has a sidecar), which is the
#                         behaviour this fixture exists to pin down.
#                         Mutually exclusive with <slug>.review and <slug>.review-once; shares
#                         the same <slug>.review-once.calls counter file.
#   <slug>.nocommit       do not create a commit in the worktree
#   <slug>.shared         write src/shared.txt (one line, the slug) instead of src/<slug>.txt,
#                         so two such issues conflict when the second one merges. A worker
#                         dispatched into a worktree with a merge in progress resolves it
#                         first, keeping both sides' lines (ours first), as crew-coder is told to.
#   <slug>.no-resolve     a worker dispatched into a merge in progress aborts it instead
#                         of resolving it, so the branch conflicts again at the merge gate.
#   <slug>.exit           exit with this code instead of 0
#
# Every fixture's own content — whatever this script writes to --out, whether from a default
# above or a <slug>.worker/.review/... file a test dropped — is expected to carry the fenced
# ```json block report.mjs actually reads. mirror_sidecar() (below) copies the *last* such
# block into --report-path, the same file a real agent's own Write tool call would produce —
# so a fixture whose content has no fenced json at all (to exercise the fail-closed "no
# sidecar" path on purpose) correctly leaves none written.
#
# `--agent prd-audit` stands in for the agent-less PRD audit (after Phase 1). Its answer is
#   $CREW_FAKE_DIR/prd-audit.response when present, else a clean report with nothing missing.
# `--agent commands-discovery` stands in for the agent-less one-time command-discovery
# dispatch (see orchestrator/lib/commands.mjs) — answers with commands matching the
# Makefile fixtureRepo() always writes (test/lint/typecheck targets), so a real
# write-commands-cache.sh run on the fake answer succeeds the same way a real model's would.
# A test that needs a different answer (e.g. a discovered "install" override) can drop a
# custom response at $CREW_FAKE_DIR/commands.response — read verbatim instead of the default.
set -uo pipefail

AGENT=""; DIR=""; PROMPT_FILE=""; OUT=""; SLUG_ARG=""; REPORT_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --slug) SLUG_ARG="$2"; shift 2 ;;
    --report-path) REPORT_PATH="$2"; shift 2 ;;
    --model) shift 2 ;;
    *) shift ;;
  esac
done

# $CREW_FAKE_ECHO_ENV names one env var; its value as this child saw it goes to
# $CREW_FAKE_DIR/env.<agent>, so a test can assert what a dispatch inherits.
if [ -n "${CREW_FAKE_ECHO_ENV:-}" ] && [ -n "${CREW_FAKE_DIR:-}" ]; then
  echo "$CREW_FAKE_ECHO_ENV=${!CREW_FAKE_ECHO_ENV:-}" > "$CREW_FAKE_DIR/env.$AGENT"
fi

# report.mjs reads only the sidecar at --report-path, never --out's text — the same contract
# a real agent's own Write tool call fulfils. Every branch below still writes --out (kept for
# a human debugging a test failure, and because dispatch.mjs always writes it), but mirrors
# the last fenced ```json block out of that same text into the sidecar, once, right before
# exiting — a fixture that wants a *missing* sidecar (to exercise the fail-closed path) writes
# --out text with no fenced json block at all, and none is mirrored.
mirror_sidecar() {
  [ -n "$REPORT_PATH" ] || return 0
  local body
  body=$(awk '
    /^[ \t]*```(json)?[ \t]*$/ { if (inside) { inside=0 } else { inside=1; buf=""; next } }
    inside { buf = buf $0 "\n" }
    END { if (found) printf "%s", buf }
    /^[ \t]*```(json)?[ \t]*$/ { found=1 }
  ' "$OUT" 2>/dev/null)
  [ -n "$body" ] && printf '%s' "$body" > "$REPORT_PATH"
}
trap mirror_sidecar EXIT

# --slug is the real dispatch's own slug (see dispatch.mjs's --slug forwarding), independent
# of --out's filename convention. Only a call with no --slug at all (prd-audit,
# commands-discovery — both exit before SLUG is used) falls back to deriving it from --out.
# pipeline.mjs forwards its own dispatchStem (`<issue-number>-<slug>`, e.g. "1-alpha") here,
# not the bare slug — stripped back to the bare form so it still matches every fixture file
# below, which every test writes by the issue's plain slug (e.g. "alpha.worker").
SLUG="${SLUG_ARG:-$(basename "$OUT" | sed -E 's/\.(report|review)\.md$//')}"
SLUG="$(printf '%s' "$SLUG" | sed -E 's/^[0-9]+-//')"
FAKE_DIR="${CREW_FAKE_DIR:?CREW_FAKE_DIR must be set}"
mkdir -p "$(dirname "$OUT")"

# Stands in for the real bash dispatchers' own throttled [TOOL] line on stdout (see
# dispatch-agent.sh/dispatch-codex-agent.sh's maybe_heartbeat), so PR 2's dispatch.mjs ->
# onTrace plumbing is exercisable for zero tokens.
if [ -f "$FAKE_DIR/$SLUG.heartbeat" ]; then
  echo "[TOOL] agent=$AGENT tool=fake-heartbeat-1 \$ echo one"
  echo "[TOOL] agent=$AGENT tool=fake-heartbeat-2 \$ echo two"
fi

if [ -f "$FAKE_DIR/$SLUG.exit" ]; then
  : > "$OUT"
  exit "$(cat "$FAKE_DIR/$SLUG.exit")"
fi

if [ "$AGENT" = "prd-audit" ]; then
  if [ -f "$FAKE_DIR/prd-audit.response" ]; then
    cat "$FAKE_DIR/prd-audit.response" > "$OUT"
  else
    printf '## PRD Audit\n\n✓ 1 covered · ⚠ 0 partial · ✗ 0 missing\n\n```json\n{"covered": 1, "partial": 0, "missing": []}\n```\n' > "$OUT"
  fi
  exit 0
fi

if [ "$AGENT" = "commands-discovery" ]; then
  if [ -f "$FAKE_DIR/commands.response" ]; then
    cat "$FAKE_DIR/commands.response" > "$OUT"
  else
    # A real model, following discover-commands.sh's prompt, always answers all eight fields —
    # including a confirmed null for the five the fixture's own Makefile never documents.
    printf '{"test": "make test", "lint": "make lint", "typecheck": "make typecheck", "install": null, "env": null, "credential_target": null, "coverage": null, "integration": null}' > "$OUT"
  fi
  exit 0
fi

if [ "$AGENT" = "crew-reviewer" ]; then
  if [ -f "$FAKE_DIR/$SLUG.review-once" ] || [ -f "$FAKE_DIR/$SLUG.review-once-garbled" ]; then
    COUNT_FILE="$FAKE_DIR/$SLUG.review-once.calls"
    COUNT=0
    [ -f "$COUNT_FILE" ] && COUNT=$(cat "$COUNT_FILE")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$COUNT_FILE"
    if [ "$COUNT" -eq 1 ]; then
      if [ -f "$FAKE_DIR/$SLUG.review-once-garbled" ]; then
        printf 'Looks fine to me.\n' > "$OUT" # non-empty, no AC: line, no findings — a truncated capture
      else
        : > "$OUT" # empty report — the pipeline reads this as review-not-run
      fi
    else
      printf '## Branch: crew/x/%s\n```json\n{"branch":"crew/x/%s","slug":"%s","verdict":"all-met","detail":"","findings":[]}\n```\n' "$SLUG" "$SLUG" "$SLUG" > "$OUT"
    fi
    exit 0
  fi
  if [ -f "$FAKE_DIR/$SLUG.review" ]; then
    cat "$FAKE_DIR/$SLUG.review" > "$OUT"
  else
    printf '## Branch: crew/x/%s\n```json\n{"branch":"crew/x/%s","slug":"%s","verdict":"all-met","detail":"","findings":[]}\n```\n' "$SLUG" "$SLUG" "$SLUG" > "$OUT"
  fi
  exit 0
fi

# Worker: make a real commit so the branch has content to verify and merge.
if [ ! -f "$FAKE_DIR/$SLUG.nocommit" ]; then
  (
    cd "$DIR" || exit 1
    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      if [ -f "$FAKE_DIR/$SLUG.no-resolve" ]; then
        git merge --abort >/dev/null 2>&1
        exit 0
      fi
      for f in $(git diff --name-only --diff-filter=U); do
        { git show ":2:$f"; git show ":3:$f"; } | awk '!seen[$0]++' > "$f"
        git add "$f"
      done
      git -c user.email=fake@test -c user.name=fake commit -q --no-edit >/dev/null 2>&1
      exit 0
    fi
    mkdir -p src
    if [ -f "$FAKE_DIR/$SLUG.shared" ]; then
      echo "$SLUG" > src/shared.txt
    else
      echo "// $SLUG" >> "src/$SLUG.txt"
    fi
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
