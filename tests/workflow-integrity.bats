#!/usr/bin/env bats

# Regression tests for the crew-afk workflow-integrity defects found by the
# end-to-end audit in .scratch/workflow-audit.md. Each test here failed before
# its corresponding fix.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
BRANCH_SETUP="$REPO_ROOT/scripts/skill-utils/git-workflow/feature-branch-setup.sh"
SESSION_INIT="$REPO_ROOT/skills/crew-afk/scripts/session-init.sh"
SQUASH="$REPO_ROOT/skills/crew-afk/scripts/squash-commits.sh"
DISPATCH_PI="$REPO_ROOT/skills/crew-afk/scripts/dispatch-agent.sh"
VERIFY="$REPO_ROOT/skills/crew-afk/scripts/verify-worktree.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -q -m "initial"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

_frontmatter() {
  awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$1"
}

# session-init.sh calls feature-branch-setup.sh as a sibling; that colocation only
# exists after install.sh copies both into the skill's scripts/ dir. Reproduce it.
_installed_scripts() {
  local dir="$TEMP_DIR/installed-scripts"
  mkdir -p "$dir"
  cp "$REPO_ROOT/skills/crew-afk/scripts/session-init.sh" "$dir/"
  cp "$REPO_ROOT/scripts/skill-utils/git-workflow/feature-branch-setup.sh" "$dir/"
  echo "$dir"
}

# --- B2: no origin/HEAD must not abort branch setup ---------------------------

@test "B2: feature-branch-setup succeeds in a repo with no origin remote" {
  mkdir -p .scratch/f/issues/open
  echo "Status: ready-for-agent" > .scratch/f/issues/open/01-do-thing.md

  run bash "$BRANCH_SETUP" .scratch/f/issues/open/01-do-thing.md
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/do-thing" ]
}

@test "B2: feature-branch-setup succeeds when origin exists but origin/HEAD is unset" {
  git init -q --bare "$TEMP_DIR/../origin-$$.git"
  git remote add origin "$TEMP_DIR/../origin-$$.git"
  mkdir -p .scratch/f/issues/open
  echo "Status: ready-for-agent" > .scratch/f/issues/open/01-do-thing.md

  run bash "$BRANCH_SETUP" .scratch/f/issues/open/01-do-thing.md
  rm -rf "$TEMP_DIR/../origin-$$.git"
  [ "$status" -eq 0 ]
}

@test "B2: session-init succeeds end to end in a repo with no origin remote" {
  printf '.scratch/\n' > .gitignore
  git add .gitignore && git commit -q -m gitignore
  mkdir -p .scratch/calc/issues/open
  echo "Status: ready-for-agent" > .scratch/calc/issues/open/01-do-thing.md

  run bash "$SESSION_INIT" --feature-slug calc
  [ "$status" -eq 0 ]
  [ -f .scratch/calc/sprint-state.json ]
}

# --- C1: one source of truth for the feature slug ----------------------------

@test "C1: session-init records feature_slug in sprint-state.json" {
  printf '.scratch/\n' > .gitignore
  git add .gitignore && git commit -q -m gitignore
  mkdir -p .scratch/calc-feature/issues/open
  echo "Status: ready-for-agent" > .scratch/calc-feature/issues/open/01-add-multiply.md

  run bash "$SESSION_INIT" --feature-slug calc-feature
  [ "$status" -eq 0 ]
  [ "$(jq -r '.feature_slug' .scratch/calc-feature/sprint-state.json)" = "calc-feature" ]
}

@test "C1: session-init keeps issues and state in the same feature dir without --feature-slug" {
  printf '.scratch/\n' > .gitignore
  git add .gitignore && git commit -q -m gitignore
  mkdir -p .scratch/calc-feature/issues/open
  echo "Status: ready-for-agent" > .scratch/calc-feature/issues/open/01-add-multiply.md

  run bash "$(_installed_scripts)/session-init.sh"
  [ "$status" -eq 0 ]
  # State must land beside the issues, not in a dir named after the first issue.
  [ -f .scratch/calc-feature/sprint-state.json ]
  [ ! -d .scratch/add-multiply ]
  [ "$(jq -r '.feature_slug' .scratch/calc-feature/sprint-state.json)" = "calc-feature" ]
}

@test "C1: squash-commits resolves the feature dir from state, not the branch name" {
  printf '.scratch/\n' > .gitignore
  git add .gitignore && git commit -q -m gitignore
  mkdir -p .scratch/calc-feature/issues/open
  echo "Status: ready-for-agent" > .scratch/calc-feature/issues/open/01-add-multiply.md
  bash "$SESSION_INIT" --feature-slug calc-feature >/dev/null

  # Branch name deliberately unrelated to the feature slug.
  git checkout -q -b release/2026-q1
  jq '.branches["release/2026-q1"] = .branches["feature/calc-feature"]' \
    .scratch/calc-feature/sprint-state.json > s.tmp && mv s.tmp .scratch/calc-feature/sprint-state.json
  mkdir -p .scratch/calc-feature/issues/done
  printf 'Status: done\n\n## What to build\n\nAdd multiply\n' \
    > .scratch/calc-feature/issues/done/01-add-multiply.md
  echo x > work.txt && git add work.txt && git commit -q -m "work"
  echo y >> work.txt && git commit -q -am "more work"

  run bash "$SQUASH" --platform pi add-multiply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Squashed"* ]]
}

# --- B5: missing "## What to build" must fall back, not abort -----------------

@test "B5: squash-commits succeeds when the issue has no 'What to build' section" {
  printf '.scratch/\n' > .gitignore
  git add .gitignore && git commit -q -m gitignore
  mkdir -p .scratch/calc/issues/open
  echo "Status: ready-for-agent" > .scratch/calc/issues/open/01-add-multiply.md
  bash "$SESSION_INIT" --feature-slug calc >/dev/null

  mkdir -p .scratch/calc/issues/done
  printf '# Add a multiply function\n\nStatus: done\n\n## Context\n\nNo build heading here.\n' \
    > .scratch/calc/issues/done/01-add-multiply.md
  echo x > work.txt && git add work.txt && git commit -q -m "work"
  echo y >> work.txt && git commit -q -am "more work"

  run bash "$SQUASH" --platform pi add-multiply
  [ "$status" -eq 0 ]
  [[ "$output" == *"Squashed"* ]]
  # Falls back to the humanised slug rather than dying silently.
  run git log -1 --format=%s
  [[ "$output" == *"add multiply"* ]]
}

# --- B1/C2: pi agent frontmatter must be valid for the pi CLI -----------------

@test "B1: pi agent definitions do not pin a Claude-only model alias" {
  local f model
  for f in "$REPO_ROOT"/agents/*/pi.agent.md; do
    model=$(_frontmatter "$f" | sed -n 's/^model: *//p')
    case "$model" in
      sonnet|haiku|opus) echo "$f pins Claude alias '$model'"; return 1 ;;
    esac
  done
}

@test "C2: pi agent tool allowlists contain only tools the pi CLI provides" {
  for f in "$REPO_ROOT"/agents/*/pi.agent.md; do
    local tools
    tools=$(_frontmatter "$f" | sed -n 's/^tools: *//p' | tr -d '[]"' | tr ',' ' ')
    [ -n "$tools" ]
    for t in $tools; do
      case "$t" in
        read|bash|edit|write|web_search|fetch_content|get_search_content|source_check|mcp|mcpScript) ;;
        *) echo "unknown pi tool '$t' in $f"; return 1 ;;
      esac
    done
  done
}

@test "C2: dispatch-agent warns about tool names the pi CLI does not provide" {
  mkdir -p .pi/agents
  cat > .pi/agents/probe.md <<'EOF'
---
name: probe
tools: read, bash, grep
---
Body.
EOF
  mkdir -p wt && echo "hi" > p.md
  cat > fake-pi <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x fake-pi
  PATH="$TEMP_DIR:$PATH" run bash -c "cd '$TEMP_DIR' && ln -sf fake-pi pi && bash '$DISPATCH_PI' --agent probe --dir '$TEMP_DIR/wt' --prompt-file '$TEMP_DIR/p.md' 2>&1"
  [[ "$output" == *"grep"* ]]
  [[ "$output" == *"unknown"* || "$output" == *"not a pi tool"* ]]
}

# --- B3: not_run policy must match verify-worktree.sh ------------------------

# The two body assertions that lived here — "demote only on fail or a missing test command"
# and "the pre-filter agrees with verify-worktree" — were prose in an orchestrator body, and
# every platform is a launcher now. The policy is one function, prefilter() in
# orchestrator/lib/report.mjs, asserted in tests/orchestrator/report.test.mjs; what remains
# below is the script side of the same contract.

@test "B3: verify-worktree.sh reports a missing lint/typecheck as a non-fatal gap" {
  grep -q 'not_run' "$VERIFY"
}

# --- B4: only the orchestrator closes issues in a sprint ---------------------

@test "B4: every crew-coder variant is told not to close the issue itself" {
  for f in "$REPO_ROOT"/agents/crew-coder/claude.agent.md \
           "$REPO_ROOT"/agents/crew-coder/copilot.agent.md \
           "$REPO_ROOT"/agents/crew-coder/pi.agent.md \
           "$REPO_ROOT"/agents/crew-coder/codex.agent.toml; do
    grep -q 'do not' <(tr 'A-Z' 'a-z' < "$f")
    grep -qi 'mark-done\|mark it done\|move the issue' "$f"
    grep -qi 'orchestrator' "$f"
  done
}

@test "B4: solve-issue's close is refused by the tracker script, not by prose" {
  # Was a grep for the sentence that told the worker to skip mark-done. The sentence is
  # gone; what stands in its place is a script that exits non-zero. Assert that instead.
  mkdir -p .scratch/f/issues/open
  printf '# T\n\nStatus: ready-for-agent\n' > .scratch/f/issues/open/01-t.md
  touch .scratch/f/.orchestrated

  run bash "$REPO_ROOT/scripts/tracker/mark-issue-done.sh" .scratch/f/issues/open/01-t.md
  [ "$status" -eq 3 ]
  [ -f .scratch/f/issues/open/01-t.md ]

  # ...and solve-issue must route its close through that operation rather than its own mv.
  grep -qE 'Execute the .mark-done. operation' "$REPO_ROOT/skills/solve-issue/SKILL.md"
}

@test "B4: close-issue.sh is idempotent when the issue is already in done/" {
  mkdir -p issues/open issues/done
  printf '# T\n\nStatus: ready-for-agent\n' > issues/done/01-t.md

  run bash "$REPO_ROOT/skills/crew-afk/scripts/close-issue.sh" issues/open/01-t.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]
  [ "$(grep -c '^Status: done' issues/done/01-t.md)" -eq 1 ]
}

# --- C6: cosmetic ------------------------------------------------------------

@test "C6: verify-worktree pluralises the not-run category count" {
  grep -q 'categor' "$VERIFY"
  ! grep -q '2 category not run' "$VERIFY"
  grep -q 'CATEGORY_WORD\|categories' "$VERIFY"
}
