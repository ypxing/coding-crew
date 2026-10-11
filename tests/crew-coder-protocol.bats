#!/usr/bin/env bats

# crew-coder is one agent with four platform bindings, not four agents.
#
# It used to be four near-identical bodies — pi 1,165 / claude 1,121 / copilot 1,142 /
# codex 1,196 words, ~4,600 maintained words for one agent — and they had already
# drifted 109 lines apart between pi and claude alone. The drift was not cosmetic: one
# variant's `partial` definition told the worker to write `## Progress` *in the issue
# file*, which the one-writer rule forbids, while another said only "write notes to
# `## Progress`". This is the same disease the dispatch bodies had, and the same cure:
# `{{PROTOCOL}}` (see orchestrator/roles/reviewer.md for the precedent).
#
# What each layer owns:
#   protocol.md      everything platform-neutral — read by all four
#   <platform>.*     frontmatter/TOML keys + `## Platform Notes`, nothing else
#
# Assertions run against the *installed* body (helpers/render.bash `coder_variant`),
# because that is the file a worker is given. They check the rendering, never the wording.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
ROLES_DIR="$REPO_ROOT/orchestrator/roles"
PROTOCOL="$ROLES_DIR/coder.md"

# ─── the protocol exists and is what gets inlined ─────────────────────────────

@test "orchestrator/roles/coder.md exists" {
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

# ─── the frontmatter/TOML contract each platform is dispatched under ──────────

@test "codex's inlined protocol cannot terminate its own literal block" {
  # A ''' inside the protocol would end developer_instructions early and truncate the
  # body — silently, since TOML would still parse.
  ! grep -q "'''" "$PROTOCOL"
}
