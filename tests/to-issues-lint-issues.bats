#!/usr/bin/env bats

# lint-issues.sh — read-only checker for a feature's issue set. ERROR = breaks dispatch or the
# gates (exit 1); WARN = judgement call (exit 0); usage error = exit 2.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LINT="$REPO_ROOT/skills/to-issues/scripts/lint-issues.sh"
  FIX="$REPO_ROOT/tests/fixtures/lint-issues"
  # A mutable copy of the clean set for the error cases.
  W="$BATS_TEST_TMPDIR/set"
  mkdir -p "$W"
  cp -R "$FIX/clean/." "$W/"
}

issues() { ls "$1"/issues/*.md | sed 's/^/--issue /' | tr '\n' ' '; }

lint_clean() { # extra args
  # shellcheck disable=SC2046
  run bash "$LINT" $(issues "$W") "$@"
}

@test "clean set with deps and PRD: no output, exit 0" {
  lint_clean --deps "$W/issues/issues-deps.json" --prd "$W/PRD.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "legacy set (Part of Flow, ten-category cross-cutting, no Implements) exits 0" {
  # shellcheck disable=SC2046
  run bash "$LINT" $(issues "$FIX/legacy")
  [ "$status" -eq 0 ]
  [[ "$output" != *ERROR* ]]
}

@test "promote-findings-shaped issue exits 0" {
  run bash "$LINT" --issue "$FIX/promoted/issues/50-fix-finding.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *ERROR* ]]
}

@test "usage: unknown flag, no --issue, unreadable file all exit 2" {
  run bash "$LINT" --bogus
  [ "$status" -eq 2 ]
  run bash "$LINT"
  [ "$status" -eq 2 ]
  run bash "$LINT" --issue "$W/issues/nope.md"
  [ "$status" -eq 2 ]
  run bash "$LINT" --issue "$W/issues/01-store.md" --prd "$W/missing.md"
  [ "$status" -eq 2 ]
  run bash "$LINT" --issue "$W/issues/01-store.md" --deps "$W/missing.json"
  [ "$status" -eq 2 ]
}

@test "ERROR: dependency cycle names the issues in it" {
  sed -i.bak 's/^None - can start immediately$/- 03-docs.md/' "$W/issues/01-store.md"
  lint_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"cycle"* ]]
  [[ "$output" == *01-store.md* && "$output" == *02-cli.md* && "$output" == *03-docs.md* ]]
}

@test "ERROR: Blocked by filename and Issue #n matching no issue in the set" {
  printf '\n- 99-ghost.md\n- Issue #77\n' >> "$W/issues/02-cli.md"
  lint_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"99-ghost.md"* ]]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"Issue #77"* ]]
}

@test "Blocked by filename containing issue-<n> is not also parsed as an Issue #<n> reference" {
  cp "$W/issues/01-store.md" "$W/issues/fix-issue-3-thing.md"
  printf '\n- fix-issue-3-thing.md\n' >> "$W/issues/02-cli.md"
  lint_clean
  [[ "$output" != *"Issue #3"* ]]
  [[ "$output" != *"ERROR "*"02-cli.md"* ]]
}

@test "ERROR: --deps edges differ from Blocked by prose, naming issue and both lists" {
  cat > "$W/issues/issues-deps.json" <<'J'
{"01-store.md": [], "02-cli.md": [], "03-docs.md": ["02-cli.md", "01-store.md"]}
J
  lint_clean --deps "$W/issues/issues-deps.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"02-cli.md: --deps edges differ from ## Blocked by: deps=[] prose=[01-store.md]"* ]]
  [[ "$output" == *"03-docs.md: --deps edges differ from ## Blocked by: deps=[01-store.md, 02-cli.md] prose=[02-cli.md]"* ]]
}

@test "ERROR: issue with no Acceptance criteria section" {
  sed -i.bak '/^## Acceptance criteria$/,/^## Interfaces$/{/^## Interfaces$/!d;}' "$W/issues/01-store.md"
  lint_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"01-store.md: "*"## Acceptance criteria"* ]]
}

@test "WARN: criteria count outside 3-8 (too few and too many); exit 0" {
  sed -i.bak '/^- \[ \] Third criterion$/d' "$W/issues/01-store.md"
  for i in 4 5 6 7 8 9; do sed -i.bak "s/^- \[ \] Second criterion\$/&\n- [ ] extra $i/" "$W/issues/02-cli.md"; done
  lint_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN "*"01-store.md: "*"2 acceptance criteria"* ]]
  [[ "$output" == *"WARN "*"02-cli.md: "*"8 acceptance criteria"* || "$output" == *"WARN "*"02-cli.md: "*"9 acceptance criteria"* ]]
}

@test "WARN: PRD ID no issue Implements" {
  printf -- '- **D9** Orphan decision.\n' >> "$W/PRD.md"
  lint_clean --prd "$W/PRD.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN "*"PRD.md: "*D9* ]]
  [[ "$output" != *D1* ]]
}

@test "WARN: blocked-on issue without Exposes, no What to build, no Implements" {
  sed -i.bak '/^### Exposes:$/d' "$W/issues/01-store.md"
  sed -i.bak '/^## What to build$/d' "$W/issues/03-docs.md"
  sed -i.bak '/^## Implements$/d' "$W/issues/03-docs.md"
  lint_clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN "*"01-store.md: "*"Exposes"* ]]
  [[ "$output" == *"WARN "*"03-docs.md: "*"## What to build"* ]]
  [[ "$output" == *"WARN "*"03-docs.md: "*"## Implements"* ]]
  [[ "$output" != *"02-cli.md: "*Exposes* ]]
}

@test "coverage check skipped silently without --prd, and for a PRD with no IDs" {
  sed -i.bak '/^## Implements$/,/^## Acceptance criteria$/{/^## Acceptance criteria$/!d;}' "$W/issues/01-store.md"
  lint_clean
  [[ "$output" != *D1* ]]
  printf '# PRD\n\nNo ids here, D1 mentioned inline.\n' > "$W/bare.md"
  lint_clean --prd "$W/bare.md"
  [[ "$output" != *bare.md* ]]
  [ "$status" -eq 0 ]
}

@test "shell metacharacters and path-like Blocked by entries are data: reported, never executed or opened" {
  local canary="$BATS_TEST_TMPDIR/pwned"
  {
    printf '\n- ../../etc/passwd\n'
    printf -- '- `touch %s`\n' "$canary"
    printf -- '- $(touch %s)\n' "$canary"
    printf -- '- ../01-store.md\n'
  } >> "$W/issues/02-cli.md"
  printf '\n$(touch %s)\n`touch %s`\n; touch %s\n' "$canary" "$canary" "$canary" >> "$W/issues/01-store.md"
  lint_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"../../etc/passwd"* ]]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"../01-store.md"* ]]
  [ ! -e "$canary" ]
}

@test "install ships lint-issues.sh as a to-issues asset and inside the skill dir, executable" {
  local target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target"
  git -C "$target" init -q -b main
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" claude --skill to-issues
  [ "$status" -eq 0 ]
  [ -x "$target/.coding-crew/to-issues/scripts/lint-issues.sh" ]
  [ -x "$target/.claude/skills/to-issues/scripts/lint-issues.sh" ]
}
