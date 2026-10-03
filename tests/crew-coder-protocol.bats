#!/usr/bin/env bats

# crew-coder is one agent with four platform bindings, not four agents.
#
# It used to be four near-identical bodies — pi 1,165 / claude 1,121 / copilot 1,142 /
# codex 1,196 words, ~4,600 maintained words for one agent — and they had already
# drifted 109 lines apart between pi and claude alone. The drift was not cosmetic: one
# variant's `partial` definition told the worker to write `## Progress` *in the issue
# file*, which the one-writer rule forbids, while another said only "write notes to
# `## Progress`". This is the same disease the dispatch bodies had, and the same cure:
# `{{PROTOCOL}}` (see agents/crew-reviewer/protocol.md for the precedent).
#
# What each layer owns:
#   protocol.md      everything platform-neutral — read by all four
#   <platform>.*     frontmatter/TOML keys + `## Platform Notes`, nothing else
#
# Assertions run against the *installed* body (helpers/render.bash `coder_variant`),
# because that is the file a worker is given.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
CODER_DIR="$REPO_ROOT/agents/crew-coder"
PROTOCOL="$CODER_DIR/protocol.md"

# body_of <platform> — the protocol as crew-afk dispatches it to that platform (no agent file).
body_of() {
  cat "$(coder_variant "$1")"
}

# ─── the protocol exists and is what gets inlined ─────────────────────────────

@test "agents/crew-coder/protocol.md exists" {
  [ -f "$PROTOCOL" ]
}

@test "the installed body carries no surviving placeholder" {
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    ! grep -q '{{PROTOCOL}}' "$f" || { echo "$p: {{PROTOCOL}} not substituted" >&2; return 1; }
    ! grep -qE '\{\{[A-Za-z_]+\}\}' "$f" || {
      echo "$p: unsubstituted placeholder:" >&2; grep -nE '\{\{[A-Za-z_]+\}\}' "$f" >&2; return 1; }
  done
}

@test "the protocol is inlined verbatim, not paraphrased" {
  # Every non-blank protocol line must appear in every installed body.
  for p in "${CODER_VARIANTS[@]}"; do
    local f missing
    f=$(coder_variant "$p")
    missing=$(grep -vE '^[[:space:]]*$' "$PROTOCOL" | while IFS= read -r line; do
      grep -qxF -- "$line" "$f" || printf '%s\n' "$line"
    done)
    [ -z "$missing" ] || { echo "$p is missing protocol lines:" >&2; echo "$missing" >&2; return 1; }
  done
}

# ─── parity: identical modulo the platform block ──────────────────────────────

# ─── the frontmatter/TOML contract each platform is dispatched under ──────────

@test "codex's inlined protocol cannot terminate its own literal block" {
  # A ''' inside the protocol would end developer_instructions early and truncate the
  # body — silently, since TOML would still parse.
  ! grep -q "'''" "$PROTOCOL"
}

# ─── the stale claim finding 6 named ─────────────────────────────────────────

@test "no body claims solve-issue unconditionally installs dependencies" {
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    ! grep -qE 'installs deps|installs dependencies( itself)?[,.]' "$f" || {
      echo "$p still claims solve-issue installs deps unconditionally:" >&2
      grep -nE 'installs deps|installs dependencies' "$f" >&2
      return 1; }
  done
  # ...and the true rule is stated once, in the protocol.
  grep -q 'installs dependencies only when' "$PROTOCOL"
}

# ─── nothing was lost in the extraction ──────────────────────────────────────

@test "every instruction the four bodies carried before the extraction survives" {
  # The union of what pi/claude/copilot/codex each said, sampled at the facts a worker
  # acts on. Asserted against the rendered body, per platform — not reviewed by eye.
  #
  # A handful of entries here are the JSON schema's equivalents of markdown headings the
  # 1.28.2 report-shape fix retired on purpose (`## Issue: <slug>`, `### Acceptance
  # Criteria`, `### Changes`, `### Notes`, the pipe-joined `Status:` line) — see CHANGELOG
  # and "the report's worked example" test below. Checking for the old heading text would
  # pin the very duplication that fix removed. Likewise, the per-worker `[START]`/`[DONE]`
  # trace file (`Agent Trace Logging`) was retired on purpose in a later change: nothing
  # ever read it back (report.mjs reads only the `<slug>.report.json` sidecar), so it was
  # a write with no reader — see CHANGELOG.
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    for phrase in \
      'Issue tracker: local only' \
      'Never query `gh`' \
      'MAIN_ROOT' \
      'PROJECT_ROOT' \
      'is not a worktree' \
      'solve-issue' \
      'dep-install' \
      'tdd' \
      'BLOCKED: solve-issue skill not installed' \
      '2 consecutive' \
      'reading `Status: complete`, `Status: partial`,' \
      '"criteria":' \
      'Cross-cutting Requirements' \
      '"notes":' \
      'report.json' \
      'not_run' \
      'Do not write to the issue file' \
      '[WIP]' \
      'refactor-validation'; do
      grep -qF "$phrase" "$f" || {
        echo "$p lost: $phrase" >&2; return 1; }
    done
  done
}

@test "the report's worked example ships once, and it is the partial one" {
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    [ "$(grep -c '^Status: partial$' "$f")" -eq 1 ]
    ! grep -q '^Status: complete$' "$f"
  done
}

@test "no variant tells the worker to write ## Progress into the issue file" {
  # claude's `partial` definition said exactly this, contradicting the one-writer rule.
  # Asserted as the rule, not as a sentence: the remaining work travels in the report's
  # `progress` field, and the ownership line forbids every issue-file write.
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    ! grep -q '`## Progress` in the issue file' "$f" || {
      echo "$p still writes ## Progress itself" >&2; return 1; }
    grep -qF '"progress"' "$f"
    grep -qF 'Do not write to the issue file' "$f"
  done
}

# ─── and the duplication does not come back ──────────────────────────────────

@test "the report wire carries cause and evidence, required for blocked" {
  # A coder's `partial` used to be taken at its word and restarted from scratch, re-deriving
  # the same blocker. The orchestrator now routes a stopped-short report through verify and
  # triage, and triage needs the one command the coder says shows why it stopped.
  for p in "${CODER_VARIANTS[@]}"; do
    body_of "$p" | grep -qF '"cause":"environment|code","evidence":{"command":' || {
      echo "$p: the schema lacks cause/evidence" >&2; return 1; }
    body_of "$p" | grep -qE '`blocked` requires `cause` and `evidence`' || {
      echo "$p: cause/evidence not required for blocked" >&2; return 1; }
  done
}
