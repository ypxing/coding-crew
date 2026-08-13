#!/usr/bin/env bats

# crew-coder is one agent with four platform bindings, not four agents.
#
# It used to be four near-identical bodies — pi 1,165 / claude 1,121 / copilot 1,142 /
# codex 1,196 words, ~4,600 maintained words for one agent — and they had already
# drifted 109 lines apart between pi and claude alone. The drift was not cosmetic: one
# variant's `partial` definition told the worker to write `## Progress` *in the issue
# file*, which the one-writer rule forbids, while another said only "write notes to
# `## Progress`". This is the same disease the dispatch bodies had, and the same cure:
# `{{PROTOCOL}}` (see agents/crew-code-reviewer/protocol.md for the precedent).
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

# body_of <platform> — the installed body with its frontmatter/TOML keys stripped, so
# only the prose a worker reads remains. This is the unit parity is asserted on.
body_of() {
  local f
  f=$(coder_variant "$1") || return 1
  case "$1" in
    codex) sed -n "/^developer_instructions = '''$/,/^'''$/p" "$f" | sed '1d;$d' ;;
    *)     awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' "$f" ;;
  esac
}

# platform_block_of <platform> — the `## Platform Notes` section only
platform_block_of() {
  body_of "$1" | awk '/^## Platform Notes/{f=1;next} /^## /{f=0} f'
}

# neutral_part_of <platform> — the body minus its platform block: must be identical
# across platforms, because it is one file inlined four times. Leading/trailing blank
# lines are trimmed: markdown frontmatter and a TOML literal block delimit the body
# differently, and that is layout, not instruction.
neutral_part_of() {
  body_of "$1" | awk '/^## Platform Notes/{exit} {print}' \
    | awk 'NF {p=1} p {print}' | awk '{a[NR]=$0} END {last=0; for(i=1;i<=NR;i++) if(a[i]~/[^ \t]/) last=i; for(i=1;i<=last;i++) print a[i]}'
}

# ─── the protocol exists and is what gets inlined ─────────────────────────────

@test "agents/crew-coder/protocol.md exists" {
  [ -f "$PROTOCOL" ]
}

@test "every platform file is frontmatter plus {{PROTOCOL}} plus a platform block" {
  for p in "${CODER_VARIANTS[@]}"; do
    local src
    case "$p" in
      codex) src="$CODER_DIR/codex.agent.toml" ;;
      *)     src="$CODER_DIR/$p.agent.md" ;;
    esac
    grep -q '{{PROTOCOL}}' "$src" || { echo "$src has no {{PROTOCOL}}" >&2; return 1; }
  done
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

@test "every platform's body is identical outside its platform block" {
  local ref
  ref=$(neutral_part_of pi)
  for p in "${CODER_VARIANTS[@]}"; do
    [ "$p" = "pi" ] && continue
    diff <(printf '%s\n' "$ref") <(neutral_part_of "$p") || {
      echo "$p diverges from pi outside ## Platform Notes" >&2; return 1; }
  done
}

@test "every platform has a platform block, and it is under 200 words" {
  for p in "${CODER_VARIANTS[@]}"; do
    local block words
    block=$(platform_block_of "$p")
    [ -n "$block" ] || { echo "$p has no ## Platform Notes section" >&2; return 1; }
    words=$(printf '%s\n' "$block" | wc -w | tr -d ' ')
    [ "$words" -lt 200 ] || { echo "$p platform block is $words words (budget 200)" >&2; return 1; }
  done
}

@test "the platform block holds only genuinely platform-specific content" {
  # Each block may name tools, search order, dispatch form and skill resolution. It may
  # not carry the procedure, the report contract, or the ownership rule: those are the
  # protocol's, and a copy here is where the four-way drift restarts.
  for p in "${CODER_VARIANTS[@]}"; do
    local block
    block=$(platform_block_of "$p")
    ! printf '%s\n' "$block" | grep -qi 'acceptance criteria' || {
      echo "$p platform block restates the report contract" >&2; return 1; }
    ! printf '%s\n' "$block" | grep -qi 'mark-done\|issues/done' || {
      echo "$p platform block restates issue ownership" >&2; return 1; }
    ! printf '%s\n' "$block" | grep -q 'report.json\|\[WIP\]\|\[DONE\]' || {
      echo "$p platform block restates the report transport" >&2; return 1; }
    ! printf '%s\n' "$block" | grep -qi 'red-green\|red/green' || {
      echo "$p platform block restates the implementation loop" >&2; return 1; }
  done
}

@test "platform-neutral prose lives in the protocol, never inline in a platform file" {
  # The negative of the rule above: a platform *source* file must not carry protocol prose.
  for p in "${CODER_VARIANTS[@]}"; do
    local src
    case "$p" in
      codex) src="$CODER_DIR/codex.agent.toml" ;;
      *)     src="$CODER_DIR/$p.agent.md" ;;
    esac
    for phrase in 'Issue Ownership' 'Machine-readable block' 'Agent Trace Logging' \
                  'Status definitions' 'Example Report' 'You are a software engineer'; do
      ! grep -q "$phrase" "$src" || {
        echo "$src carries protocol prose inline: $phrase" >&2; return 1; }
    done
  done
}

# ─── the frontmatter/TOML contract each platform is dispatched under ──────────

@test "pi keeps its tool allowlist and stays non-user-invocable" {
  local f
  f=$(coder_variant pi)
  grep -q '^name: crew-coder$' "$f"
  grep -q '^description: >$' "$f"
  grep -q '^tools: read, bash, edit, write$' "$f"
  grep -q '^user-invocable: false$' "$f"
}

@test "claude keeps its model pin, its withheld Agent tool, and its skills list" {
  local f
  f=$(coder_variant claude)
  grep -q '^name: crew-coder$' "$f"
  grep -q '^model: sonnet$' "$f"
  grep -q '^disallowedTools:$' "$f"
  grep -q '^  - Agent$' "$f"
  grep -q '^skills:$' "$f"
  grep -q '^  - solve-issue$' "$f"
}

@test "copilot keeps the CLI's own tool vocabulary and withholds task" {
  local f
  f=$(coder_variant copilot)
  grep -q '^name: crew-coder$' "$f"
  grep -q '^tools: \["bash", "view", "create", "edit", "grep", "glob"\]$' "$f"
  grep -q '^skills: \["solve-issue", "dep-install", "tdd"\]$' "$f"
  grep -q '^user-invocable: false$' "$f"
  ! grep -qE '^tools:.*"task"' "$f"
}

@test "codex keeps its TOML keys and its sandbox mode" {
  local f
  f=$(coder_variant codex)
  grep -q '^name = "crew-coder"$' "$f"
  grep -q '^description = ' "$f"
  grep -q '^model_reasoning_effort = "medium"$' "$f"
  grep -q '^sandbox_mode = "workspace-write"$' "$f"
  # The protocol must sit inside the literal block, so its markdown needs no escaping.
  grep -q "^developer_instructions = '''$" "$f"
  [ "$(grep -c "^'''$" "$f")" -eq 1 ]
}

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
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    for phrase in \
      'Issue tracker: local only' \
      'Never query `gh`' \
      'MAIN_ROOT' \
      'PROJECT_ROOT' \
      'is not a worktree' \
      '[START] issue=' \
      '[DONE] status=' \
      'codegraph' \
      'solve-issue' \
      'dep-install' \
      'tdd' \
      'BLOCKED: solve-issue skill not installed' \
      '2 consecutive' \
      '## Issue: <slug>' \
      'Status: complete | partial | blocked' \
      '### Acceptance Criteria' \
      'Cross-cutting Requirements' \
      '### Changes' \
      '### Notes' \
      'report.json' \
      'not_run' \
      'Do not write to the issue file' \
      '[WIP]' \
      '04-refactor-validation'; do
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

@test "one maintained body: the four platform files are small" {
  # ~4,600 words across four files is what this replaced. A platform file that grows
  # past a frontmatter block and a platform block is a fifth copy starting.
  local total=0
  for p in "${CODER_VARIANTS[@]}"; do
    local src words
    case "$p" in
      codex) src="$CODER_DIR/codex.agent.toml" ;;
      *)     src="$CODER_DIR/$p.agent.md" ;;
    esac
    words=$(wc -w < "$src" | tr -d ' ')
    [ "$words" -lt 350 ] || { echo "$(basename "$src") is $words words (budget 350)" >&2; return 1; }
    total=$((total + words))
  done
  [ "$total" -lt 1200 ] || { echo "platform files total $total words (budget 1200)" >&2; return 1; }
}
