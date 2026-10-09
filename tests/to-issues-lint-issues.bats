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

@test "Blocked by bare #n and 'Issue #a, #b' resolve like github.mjs's blockerNumbers" {
  printf '\n- #1\n' >> "$W/issues/02-cli.md"
  lint_clean
  [[ "$output" != *"ERROR "*"02-cli.md"* ]]
  printf '\n- Issue #1, #77\n' >> "$W/issues/02-cli.md"
  lint_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"Issue #77"* ]]
}

@test "Blocked by 'Issue #a, #b' contributes both edges to the cycle check" {
  # 04 blocks on nothing, so only the second ref (#3 -> 02 -> 01) closes the cycle.
  cp "$W/issues/01-store.md" "$W/issues/04-extra.md"
  sed -i.bak '/^## Blocked by/,$d' "$W/issues/01-store.md"
  printf '## Blocked by\n\n- Issue #4, #3\n' >> "$W/issues/01-store.md"
  lint_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"cycle"* ]]
}

@test "Blocked by PR #n / pull request #n is prose, not a ref, like github.mjs's blockerNumbers" {
  printf '\n- 01-store.md (needs the parser from PR #40, pull request #41, pull #42)\n' >> "$W/issues/02-cli.md"
  lint_clean
  [[ "$output" != *"ERROR "*"02-cli.md"* ]]
}

@test "Blocked by filename containing issue-<n> is not also parsed as an Issue #<n> reference" {
  cp "$W/issues/01-store.md" "$W/issues/fix-issue-3-thing.md"
  printf '\n- fix-issue-3-thing.md\n' >> "$W/issues/02-cli.md"
  lint_clean
  [[ "$output" != *"Issue #3"* ]]
  [[ "$output" != *"ERROR "*"02-cli.md"* ]]
}

@test "Blocked by filename wrapped in markup and followed by punctuation resolves and is not read as Issue #<n>" {
  cp "$W/issues/01-store.md" "$W/issues/fix-issue-3-thing.md"
  printf '\n- `fix-issue-3-thing.md`, then wait\n- **fix-issue-3-thing.md**.\n' >> "$W/issues/02-cli.md"
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

@test "criteria count: no WARN at 1-10; WARN at 11 names the context-budget check; exit 0" {
  sed -i.bak '/^- \[ \] Third criterion$/d' "$W/issues/01-store.md"
  for i in 4 5 6 7 8 9 10 11; do sed -i.bak "s/^- \[ \] Second criterion\$/&\n- [ ] extra $i/" "$W/issues/02-cli.md"; done
  f="$BATS_TEST_TMPDIR/one.md"
  printf '## What to build\n\nx\n\n## Implements\n\nB1\n\n## Acceptance criteria\n\n- [ ] only\n' > "$f"
  t="$BATS_TEST_TMPDIR/ten.md"
  { printf '## What to build\n\nx\n\n## Implements\n\nB1\n\n## Acceptance criteria\n\n'; for i in $(seq 1 10); do printf -- '- [ ] c%s\n' "$i"; done; } > "$t"
  lint_clean --issue "$f" --issue "$t"
  [ "$status" -eq 0 ]
  [[ "$output" != *"01-store.md: "*"acceptance criteria"* ]]
  [[ "$output" != *"one.md: "*"acceptance criteria"* ]]
  [[ "$output" != *"ten.md: "*"acceptance criteria"* ]]
  [[ "$output" == *"WARN "*"02-cli.md: 11 acceptance criteria"*"context-budget check"* ]]
  [[ "$output" != *"expected 3-8"* ]]
}

@test "header comment states the criteria WARN as over 10, a context-budget check" {
  grep -q '^# WARN:  more than 10 acceptance criteria (a context-budget check' "$LINT"
  ! grep -q '3-8' "$LINT"
}

@test "WARN: PRD ID no issue Implements" {
  printf -- '- **D9** Orphan decision.\n' >> "$W/PRD.md"
  lint_clean --prd "$W/PRD.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN "*"PRD.md: "*D9* ]]
  [[ "${output//$W/}" != *D1* ]]
}

@test "a PRD ID whose line ends in (no slice) needs no Implements: no coverage WARN" {
  printf -- '- **D9** Orphan decision, already true of the code. (no slice)\n' >> "$W/PRD.md"
  printf -- '- **D10** Unmarked orphan.\n' >> "$W/PRD.md"
  lint_clean --prd "$W/PRD.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *D9* ]]
  [[ "$output" == *"WARN "*"PRD.md: D10 is not named by any issue's ## Implements"* ]]
}

@test "a (no slice) ID that an issue does implement is neither an error nor a warning" {
  sed -i.bak 's/^- \*\*D1\*\* \(.*\)$/- **D1** \1 (no slice)/' "$W/PRD.md"
  grep -q '^- \*\*D1\*\* .*(no slice)$' "$W/PRD.md"
  lint_clean --deps "$W/issues/issues-deps.json" --prd "$W/PRD.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "(no slice) counts only at the end of the ID's line" {
  printf -- '- **D9** Mentions (no slice) mid-line, then more.\n' >> "$W/PRD.md"
  lint_clean --prd "$W/PRD.md"
  [[ "$output" == *"WARN "*"PRD.md: D9 is not named"* ]]
}

@test "--known: an ID named only in a known file's ## Implements needs no WARN" {
  mkdir -p "$W/issues/done"
  mv "$W/issues/01-store.md" "$W/issues/done/"
  grep -q 'D1' "$W/issues/done/01-store.md"
  run bash "$LINT" --issue "$W/issues/02-cli.md" --issue "$W/issues/03-docs.md" \
    --known "$W/issues/done/01-store.md" --prd "$W/PRD.md"
  [ "$status" -eq 0 ]
  [[ "${output//$W/}" != *D1* ]]
  # the same set without --known: D1 is uncovered (02-cli's ref also errors)
  run bash "$LINT" --issue "$W/issues/02-cli.md" --issue "$W/issues/03-docs.md" --prd "$W/PRD.md"
  [[ "$output" == *"WARN "*"PRD.md: D1 is not named"* ]]
}

@test "--known naming a file that does not exist is still only a name" {
  mkdir -p "$W/issues/done"
  mv "$W/issues/01-store.md" "$W/issues/done/"
  run bash "$LINT" --issue "$W/issues/02-cli.md" --issue "$W/issues/03-docs.md" \
    --known "$W/issues/gone/01-store.md" --prd "$W/PRD.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *ERROR* ]]
  [[ "$output" == *"WARN "*"PRD.md: D1 is not named"* ]]
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
  [[ "${output//$W/}" != *D1* ]]
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
  [[ "$output" == *"ERROR "*"02-cli.md: "*'$(touch'* ]]
  [[ "$output" != *"ERROR "*"02-cli.md: "*"../01-store.md"* ]] # matched by basename only
  [ ! -e "$canary" ]
}

@test "a path-like ref never opens the path: its basename must be in the set" {
  printf '\n- ../../elsewhere/99-ghost.md\n' >> "$W/issues/02-cli.md"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere" && cp "$W/issues/01-store.md" "$BATS_TEST_TMPDIR/elsewhere/99-ghost.md"
  lint_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"99-ghost.md"* ]]
}

@test "--known: a Blocked by ref (filename or Issue #n) to an issue outside the set resolves, and is not linted" {
  mkdir -p "$W/issues/done"
  mv "$W/issues/01-store.md" "$W/issues/done/"
  printf '\n- Issue #1\n' >> "$W/issues/02-cli.md"
  printf '{"02-cli.md": [], "03-docs.md": ["02-cli.md"]}\n' > "$W/issues/known-deps.json"
  run bash "$LINT" --issue "$W/issues/02-cli.md" --issue "$W/issues/03-docs.md" \
    --known "$W/issues/done/01-store.md" --deps "$W/issues/known-deps.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *ERROR* ]]
  [[ "$output" != *01-store.md* ]]
}

@test "--known: a deps.json edge to the --known issue is an ERROR naming it" {
  mkdir -p "$W/issues/done"
  mv "$W/issues/01-store.md" "$W/issues/done/"
  printf '\n- Issue #1\n' >> "$W/issues/02-cli.md"
  run bash "$LINT" --issue "$W/issues/02-cli.md" --issue "$W/issues/03-docs.md" \
    --known "$W/issues/done/01-store.md" --deps "$W/issues/issues-deps.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"01-store.md"* ]]
}

@test "--deps: an edge between two drafts missing from deps.json is still an error" {
  printf '{"01-store.md": [], "02-cli.md": [], "03-docs.md": ["02-cli.md"]}\n' > "$W/issues/missing.json"
  lint_clean --deps "$W/issues/missing.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--deps edges differ"* ]]
}

@test "without --known the same done-issue ref is an ERROR" {
  mkdir -p "$W/issues/done"
  mv "$W/issues/01-store.md" "$W/issues/done/"
  run bash "$LINT" --issue "$W/issues/02-cli.md" --issue "$W/issues/03-docs.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR "*"02-cli.md: "*"01-store.md"* ]]
}

@test "Blocked by prose with a slash, a path citation or a markdown link resolves by basename" {
  sed -i.bak '/^## Blocked by$/,$d' "$W/issues/02-cli.md"
  {
    printf '## Blocked by\n\n'
    printf -- '- 01-store.md (schema/API must land first)\n'
    printf -- '- Issue 01: `.scratch/feat/issues/open/01-store.md`\n'
    printf -- '- [01-store.md](../open/01-store.md)\n'
  } >> "$W/issues/02-cli.md"
  lint_clean --deps "$W/issues/issues-deps.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *ERROR* ]]
}

@test "Blocked by placeholders in markup or a bare dash mean no blocker" {
  for none in '_None_' '**None** - can start immediately' '*n/a*' '—' '-'; do
    sed -i.bak '/^## Blocked by$/,$d' "$W/issues/01-store.md"
    printf '## Blocked by\n\n%s\n' "$none" >> "$W/issues/01-store.md"
    lint_clean --deps "$W/issues/issues-deps.json"
    [ "$status" -eq 0 ] || { echo "placeholder: $none"; echo "$output"; false; }
  done
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

# --- ready-for-human issues ---

H106="tests/fixtures/lint-issues/human/issues/106-enable-main-ruleset.md"

@test "human fixture (#106 rewritten): no output, exit 0" {
  run bash "$LINT" --issue "$REPO_ROOT/$H106"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "human fixture: ruleset.json block parses and holds all five rule types" {
  json=$(sed -n '/^   ```json/,/^   ```$/p' "$REPO_ROOT/$H106" | sed '1d;$d')
  run jq -r '[.rules[].type] | sort | join(",")' <<< "$json"
  [ "$status" -eq 0 ]
  [ "$output" = "deletion,non_fast_forward,pull_request,required_linear_history,required_status_checks" ]
}

@test "ready-for-human without ## For a human: one WARN, no What to build / Implements WARN" {
  f="$BATS_TEST_TMPDIR/h.md"
  printf 'Status: ready-for-human\n\n## Acceptance criteria\n\n- [ ] a\n- [ ] b\n- [ ] c\n' > "$f"
  run bash "$LINT" --issue "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready-for-human issue has no ## For a human section"* ]]
  [[ "$output" != *"What to build"* ]]
  [[ "$output" != *"Implements"* ]]
}

@test "ready-for-human missing a ### part: WARN names it" {
  f="$BATS_TEST_TMPDIR/h.md"
  grep -v '^### Done when' "$REPO_ROOT/$H106" > "$f"
  run bash "$LINT" --issue "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "WARN $f: ## For a human has no ### Done when" ]
}

@test "ready-for-human: a ### Steps heading inside a code fence does not count" {
  f="$BATS_TEST_TMPDIR/h.md"
  sed 's/^### Steps$/```\n### Steps\n```/' "$REPO_ROOT/$H106" > "$f"
  run bash "$LINT" --issue "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## For a human has no ### Steps"* ]]
}

@test "ready-for-human without ## Acceptance criteria: still an ERROR, exit 1" {
  f="$BATS_TEST_TMPDIR/h.md"
  sed '/^## Acceptance criteria/,$d' "$REPO_ROOT/$H106" > "$f"
  run bash "$LINT" --issue "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR $f: no ## Acceptance criteria section"* ]]
}

@test "ready-for-agent issue missing What to build / Implements still gets both WARNs" {
  f="$BATS_TEST_TMPDIR/a.md"
  printf 'Status: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] a\n- [ ] b\n- [ ] c\n' > "$f"
  run bash "$LINT" --issue "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no ## What to build section"* ]]
  [[ "$output" == *"no ## Implements section"* ]]
}

@test "ready-for-human with a ticked criterion: one WARN naming it, exit 0; a ticked line in a fence does not count" {
  f="$BATS_TEST_TMPDIR/h.md"
  sed 's/^- \[ \] The four original rules are still present$/- [x] The four original rules are still present/' "$REPO_ROOT/$H106" > "$f"
  printf '\n```markdown\n- [x] fenced example\n```\n' >> "$f"
  run bash "$LINT" --issue "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "WARN $f: ready-for-human acceptance criterion is ticked — leave criteria unticked when publishing: - [x] The four original rules are still present" ]
}

@test "ready-for-agent with a ticked criterion: no ticked-criterion WARN" {
  f="$BATS_TEST_TMPDIR/a.md"
  printf 'Status: ready-for-agent\n\n## What to build\n\nx\n\n## Implements\n\nD1\n\n## Acceptance criteria\n\n- [x] a\n- [ ] b\n' > "$f"
  run bash "$LINT" --issue "$f"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# shared_issue <file> <blocked-by line> <body text> — a minimal well-formed issue naming paths in its body.
shared_issue() {
  printf 'Status: ready-for-agent\n\n## What to build\n\n%s\n\n## Implements\n\nD1\n\n## Blocked by\n\n%s\n\n## Acceptance criteria\n\n- [ ] a\n' "$3" "$2" > "$1"
}

@test "WARN: two unlinked issues naming the same file get exactly one warning, exit 0" {
  d="$BATS_TEST_TMPDIR/s"; mkdir -p "$d"
  shared_issue "$d/01-a.md" "None" "Edit \`src/a.ts\` and registry.json."
  shared_issue "$d/02-b.md" "None" "Fix the bug at src/a.ts:10, see registry.json."
  run bash "$LINT" --issue "$d/01-a.md" --issue "$d/02-b.md"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^WARN ')" -eq 1 ]
  [[ "$output" == "WARN $d/01-a.md: "*"$d/02-b.md"*"src/a.ts"* ]]
  [[ "$output" != *registry.json* ]]
}

@test "shared file: no warning when one is Blocked by the other, directly or through a third issue" {
  d="$BATS_TEST_TMPDIR/s"; mkdir -p "$d"
  shared_issue "$d/01-a.md" "None" "Edit src/a.ts."
  shared_issue "$d/02-b.md" "- 01-a.md" "Edit src/a.ts:10."
  run bash "$LINT" --issue "$d/01-a.md" --issue "$d/02-b.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *src/a.ts* ]]
  shared_issue "$d/02-b.md" "- 03-c.md" "Edit src/a.ts:10."
  shared_issue "$d/03-c.md" "- 01-a.md" "Edit src/c.ts."
  run bash "$LINT" --issue "$d/01-a.md" --issue "$d/02-b.md" --issue "$d/03-c.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *src/a.ts* ]]
}

@test "shared file: no warning against a --known issue, a PRD link or a Blocked by path" {
  d="$BATS_TEST_TMPDIR/s"; mkdir -p "$d"
  shared_issue "$d/00-done.md" "None" "Edit src/a.ts."
  shared_issue "$d/01-a.md" "- ../done/00-done.md" "Edit src/a.ts. PRD: https://example.com/x/y.md
## Context Documents

- PRD: .scratch/feat/PRD.md"
  shared_issue "$d/02-b.md" "- ../done/00-done.md" "Edit src/b.ts.
## Context Documents

- PRD: .scratch/feat/PRD.md"
  run bash "$LINT" --issue "$d/01-a.md" --issue "$d/02-b.md" --known "$d/00-done.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "shared-file WARN is advisory and points at to-issues' edge rule, not at a conflict" {
  d="$BATS_TEST_TMPDIR/s"; mkdir -p "$d"
  shared_issue "$d/01-a.md" "None" "Edit src/a.ts."
  shared_issue "$d/02-b.md" "None" "Edit src/a.ts:10."
  run bash "$LINT" --issue "$d/01-a.md" --issue "$d/02-b.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/a.ts (advisory: add a Blocked by only if to-issues' edge rule row 1 or 2 matches)" ]]
  [[ "$output" != *"may conflict"* ]]
  ! grep -q 'may conflict' "$LINT"
}

@test "header comment lists the shared-file WARN" {
  sed -n '1,/^set -uo/p' "$LINT" | grep -q -i 'same file'
}

@test "no --prd: a draft with ## Decisions and an Implements naming its own IDs exits 0 with no WARN" {
  cat > "$W/decided.md" <<'MD'
# one slice

Status: ready-for-agent

## What to build

Build the one slice.

## Decisions

- **D1** — Keep the format. Reason at `src/a.sh:3`.

## Implements

D1

## Acceptance criteria

- [ ] First criterion
- [ ] Second criterion
- [ ] Third criterion

## Blocked by

None - can start immediately
MD
  run bash "$LINT" --issue "$W/decided.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *WARN* ]]
  [[ "$output" != *ERROR* ]]
}
