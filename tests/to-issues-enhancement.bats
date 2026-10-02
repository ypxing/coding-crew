#!/usr/bin/env bats

# Tests for the to-issues skill body: issue template, criteria rubric, cross-cutting rules.
# Asserted against the rendered skill, which is what a consuming repo receives.

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SKILL_FILE="$(rendered_skill to-issues claude)"
}

# --- Template Sections ---

@test "to-issues/SKILL.md template includes Context Documents section" {
  grep -q '## Context Documents' "$SKILL_FILE"
}

@test "to-issues/SKILL.md template includes Cross-cutting Requirements section" {
  grep -q '## Cross-cutting Requirements' "$SKILL_FILE"
}

@test "to-issues template has Implements after What to build, and no Part of Flow" {
  grep -q '^## Implements$' "$SKILL_FILE"
  ! grep -q 'Part of Flow' "$SKILL_FILE"
  impl=$(grep -n '^## Implements$' "$SKILL_FILE" | head -1 | cut -d: -f1)
  # the inlined human-issue fragment has its own headings; anchor on the template around Implements
  build=$(grep -n '^## What to build$' "$SKILL_FILE" | cut -d: -f1 | awk -v i="$impl" '$1<i{b=$1} END{print b}')
  ac=$(grep -n '^## Acceptance criteria$' "$SKILL_FILE" | cut -d: -f1 | awk -v i="$impl" '$1>i{print; exit}')
  [ "$build" -lt "$impl" ]
  [ "$impl" -lt "$ac" ]
  grep -qi 'PRD IDs' "$SKILL_FILE"
  grep -qi 'verified at' "$SKILL_FILE"
}

@test "to-issues: Interfaces is included for consumers and consumed issues; a consumed root has Exposes" {
  grep -qF 'consumes from or is consumed by another' "$SKILL_FILE"
  ! grep -qF "only include this section if \`## Blocked by\` is non-empty" "$SKILL_FILE"
  grep -q '^### Exposes:$' "$SKILL_FILE"
  grep -qiE 'root issue.*(Exposes)' "$SKILL_FILE"
}

@test "to-issues: Cross-cutting Requirements carries only a PRD rule the criteria do not cover; ten-category scan is gone" {
  grep -qF 'do not already cover' "$SKILL_FILE"
  ! grep -q 'Extract cross-cutting requirements' "$SKILL_FILE"
  ! grep -qE '\(10 total\)|10 categories' "$SKILL_FILE"
  ! grep -q 'Multi-Issue Flows' "$SKILL_FILE"
}

@test "to-issues: acceptance-criteria rubric" {
  grep -qF 'one observable behaviour or consumed contract' "$SKILL_FILE"
  grep -qF 'checkable from the diff plus the checks' "$SKILL_FILE"
  grep -qF 'never "tests pass"' "$SKILL_FILE"
  grep -qF 'names the mechanism that prevents it' "$SKILL_FILE"
  grep -qF 'stay in the PRD' "$SKILL_FILE"
  grep -qF 'is itself the requirement' "$SKILL_FILE"
}

@test "to-issues: a slice taking input or calling something external carries failure-behaviour criteria" {
  grep -qE 'takes input or calls something external' "$SKILL_FILE"
  grep -qF 'invalid input, missing dependency, failing call' "$SKILL_FILE"
}

@test "to-issues: file-path ban is gone; What to build may cite grounded paths and opens with a one-line summary" {
  ! grep -q 'Avoid specific file paths' "$SKILL_FILE"
  grep -qF 'grounded paths and signatures' "$SKILL_FILE"
  grep -qF 'first sentence is a one-line summary' "$SKILL_FILE"
  grep -qF 'squash-commits.sh:109' "$SKILL_FILE"
}

# --- Extraction Logic References ---

@test "to-issues/SKILL.md names PRD.md as the context source" {
  # design.md was consolidated into PRD.md as the single context document.
  grep -q 'PRD\.md' "$SKILL_FILE"
  ! grep -q 'design\.md' "$SKILL_FILE"
}

@test "to-issues/SKILL.md mentions PRD.md fallback for requirements" {
  grep -q 'PRD\.md' "$SKILL_FILE"
}

# --- Optional Section Guidance ---

@test "to-issues/SKILL.md indicates Context Documents section is conditional" {
  grep -qi 'only if\|only when\|optional' "$SKILL_FILE"
}

@test "to-issues/SKILL.md template shows omission of optional sections when not applicable" {
  # The template should clarify that sections can be omitted
  grep -qi 'omit\|skip\|only include\|only if' "$SKILL_FILE"
}

# --- Multi-issue Flow Annotations ---


@test "to-issues/SKILL.md template includes an optional Requires section, one command per bullet" {
  grep -q '^## Requires$' "$SKILL_FILE"
  grep -q 'exit 0 = satisfied' "$SKILL_FILE"
}

@test "to-issues runs each Requires command while authoring, and a failure makes the issue ready-for-human" {
  grep -q 'Run each one while authoring' "$SKILL_FILE"
  grep -qE 'fails, publish the issue as `Status: ready-for-human`' "$SKILL_FILE"
}

@test "to-issues: codebase exploration is required, not optional" {
  # Issues drafted from the PRD alone named functions that did not exist and bugs already fixed;
  # the coder's premise check (solve-issue §3) is the backstop, this is the prevention.
  ! grep -q '^### 3\. Explore the codebase (optional)' "$SKILL_FILE"
  grep -q '^### 3\. Explore the codebase$' "$SKILL_FILE"
}

@test "to-issues: every assumption about current code is grounded at file:line, new things say so" {
  section=$(awk '/^### 3\. Explore/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$section" | grep -q 'Ground every assumption'
  echo "$section" | grep -qF 'confirm it at a `file:line`'
  echo "$section" | grep -q 'the code path that produces it'
  echo "$section" | grep -q 'its issue says so'
}

@test "to-issues: a contradicted assumption goes to the quiz, never silently into an issue" {
  section=$(awk '/^### 3\. Explore/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$section" | grep -q 'never silently into an issue'
  echo "$section" | grep -q 'Already there'
  echo "$section" | grep -q 'test-only slice'
  echo "$section" | grep -q 'Wrong assumption'
  quiz=$(awk '/^### 5\. Quiz/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$quiz" | grep -q 'Contradicted assumptions'
}

# --- Slicing, quiz, coverage trace, lint gate (rendered skill) ---

@test "to-issues slice rules: a slice is one observable behaviour at the highest existing seam; first slice is the thinnest end-to-end path" {
  grep -qF 'one externally observable behaviour' "$SKILL_FILE"
  grep -qF 'highest existing seam' "$SKILL_FILE"
  grep -qiE 'schema / API / UI.*(only )?(as )?an example|example.*schema / API / UI' "$SKILL_FILE"
  grep -qiE 'first slice is the thinnest end-to-end path' "$SKILL_FILE"
}

@test "to-issues size rules: context-window ceiling kept, merge rule replaces 'many thin slices', 3-8 criteria soft target" {
  grep -qF 'single fresh context window' "$SKILL_FILE"
  ! grep -qF 'Prefer many thin slices' "$SKILL_FILE"
  grep -qiE 'merge.*share a test seam|share a test seam.*merge' "$SKILL_FILE"
  grep -qiE 'neither is reviewable or demoable alone' "$SKILL_FILE"
  grep -qE '3(–|-)8 acceptance criteria' "$SKILL_FILE"
}

@test "to-issues quiz: ordered outlier list then one approve/adjust prompt; the five generic questions are gone" {
  local a b c d e f
  a=$(grep -n 'Contradicted assumptions' "$SKILL_FILE" | head -1 | cut -d: -f1)
  b=$(grep -n "PRD's \`## Assumptions\`" "$SKILL_FILE" | head -1 | cut -d: -f1)
  c=$(grep -n 'PRD IDs no slice covers' "$SKILL_FILE" | head -1 | cut -d: -f1)
  d=$(grep -n 'Slices outside the criteria range' "$SKILL_FILE" | head -1 | cut -d: -f1)
  e=$(grep -n 'Shared surfaces' "$SKILL_FILE" | head -1 | cut -d: -f1)
  f=$(grep -n 'HITL choices' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] && [ -n "$f" ]
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] && [ "$e" -lt "$f" ]
  grep -qiE 'one approve/adjust prompt' "$SKILL_FILE"
  ! grep -qF 'Does the granularity feel right' "$SKILL_FILE"
  ! grep -qF 'Are the blocking edges correct' "$SKILL_FILE"
  ! grep -qF 'Should any slices be merged or split further' "$SKILL_FILE"
  ! grep -qF 'Are the correct slices marked as HITL and AFK' "$SKILL_FILE"
  ! grep -qF 'For any shared surface listed above' "$SKILL_FILE"
}

@test "to-issues: a coverage table maps every D<n>/B<n> to its slices before the quiz; skipped with no IDs" {
  grep -qiE 'coverage table' "$SKILL_FILE"
  grep -qF 'D<n>' "$SKILL_FILE"
  grep -qF 'B<n>' "$SKILL_FILE"
  grep -qiE 'no IDs.*skipped' "$SKILL_FILE"
  cov=$(grep -n -i 'coverage table' "$SKILL_FILE" | head -1 | cut -d: -f1)
  quiz=$(grep -n '^### .*Quiz' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ "$cov" -le "$quiz" ]
}

@test "to-issues: expand-contract sequencing comes from the PRD's Compatibility & Migration" {
  grep -qF '## Compatibility & Migration' "$SKILL_FILE"
  grep -qiE 'expand.contract' "$SKILL_FILE"
}

@test "to-issues: lint-issues.sh gates publish; ERROR publishes nothing and returns to the quiz; WARN continues" {
  grep -qF '<skill-dir>/scripts/lint-issues.sh' "$SKILL_FILE"
  grep -qF -- '--deps' "$SKILL_FILE"
  grep -qF -- '--prd' "$SKILL_FILE"
  grep -qiE 'exit 1.*publish(es)? nothing|publish(es)? nothing.*exit 1' "$SKILL_FILE"
  grep -qF 'returns to the quiz' "$SKILL_FILE"
  grep -qiE 'WARN.*publishing continues' "$SKILL_FILE"
  lint=$(grep -n 'lint-issues.sh' "$SKILL_FILE" | head -1 | cut -d: -f1)
  pub=$(grep -n 'execute the `publish` operation' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ "$lint" -lt "$pub" ]
}

@test "to-issues: under github the lint run uses provisional Issue #<n> numbers and --known for existing milestone issues" {
  grep -qF -- '--known <number>-<slug>.md' "$SKILL_FILE"
  grep -qiE 'replace each `Issue #<n>` with the number `gh issue create` returned' "$SKILL_FILE"
}

@test "to-issues: a new parser/validator/gate gets a criterion over the repo's existing examples, as committed fixtures" {
  grep -qF 'already holds examples of' "$SKILL_FILE"
  grep -qF 'copied into committed test fixtures' "$SKILL_FILE"
  grep -qF 'never read from a live or gitignored directory' "$SKILL_FILE"
  grep -qF 'no such examples (a new format) → no such criterion' "$SKILL_FILE"
}

@test "expand-contract reference has no integration branch and directs single issue or ready-for-human" {
  f="$SCRIPT_DIR/skills/to-issues/references/expand-contract.md"
  ! grep -qi 'integration branch\|integrate-and-verify' "$f"
  grep -q 'one fresh context window' "$f"
  grep -q 'Status: ready-for-human' "$f"
  grep -q '### Why a person' "$f"
  grep -q 'per-branch verify' "$f"
}

@test "to-issues step 1 reads a referenced issue's comments via gh issue view --comments" {
  grep -q 'gh issue view <n> --comments' "$SKILL_FILE"
}

@test "github tracker fetch operation is unchanged" {
  grep -q 'gh issue view <number> \[--repo owner/name\] --json number,title,body,labels,state$' "$SCRIPT_DIR/docs/templates/trackers/github.md"
}

# --- Edge rule, overhead, quiz items (B1-B3, D3), anchored on the skill's own headings ---

@test "to-issues B1: edge rule has four rows in order, with 'at most 8' criteria and small-file merge" {
  section=$(awk '/^### 4\. Draft vertical slices/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  rows=$(echo "$section" | awk '/^\*\*Edge rule\.\*\*/{f=1;next} f && /^[0-9]+\. /{print} f && /^$/ && n++>0{exit}')
  [ "$(echo "$rows" | wc -l | tr -d ' ')" = 4 ]
  echo "$rows" | sed -n 1p | grep -q '^1\. One slice consumes what the other produces.*`Blocked by`'
  echo "$rows" | sed -n 2p | grep -q '^2\. The two change the same meaning.*`Blocked by`'
  echo "$rows" | sed -n 3p | grep -q '^3\. They edit the same small file.*at most 8 acceptance criteria.*merge them into one slice'
  echo "$rows" | sed -n 4p | grep -q '^4\. Anything else.*parallel'
  echo "$section" | grep -q 'first match wins'
}

@test "to-issues D3: per-slice overhead sentence precedes the edge rule" {
  section=$(awk '/^### 4\. Draft vertical slices/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$section" | grep -q 'Every slice costs fixed overhead before and after its code: a worktree, a deps install, a coder dispatch, verify, review and merge'
  o=$(echo "$section" | grep -n 'Every slice costs fixed overhead' | cut -d: -f1)
  e=$(echo "$section" | grep -n 'Edge rule\.' | cut -d: -f1)
  [ "$o" -lt "$e" ]
}

@test "to-issues B2: quiz lists each edge/merge with its reason, not a question per shared surface" {
  quiz=$(awk '/^### 5\. Quiz/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$quiz" | grep -q '^5\. \*\*Edges and merges the edge rule produced\*\* — one line per edge or merge'
  echo "$quiz" | grep -q 'naming the slices and the rule row (reason)'
  echo "$quiz" | grep -q "Don't ask whether an overlap needs an edge"
}

@test "to-issues B3: quiz asks whether slices can share a seam when more than two distinct seams are named" {
  quiz=$(awk '/^### 5\. Quiz/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$quiz" | grep -q '^6\. \*\*Seam count\*\*'
  echo "$quiz" | grep -q 'name more than two distinct seams'
  echo "$quiz" | grep -q 'whether some slices can share one seam'
}
