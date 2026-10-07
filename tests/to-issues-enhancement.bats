#!/usr/bin/env bats

# Tests for the to-issues skill body: issue template, criteria rubric, cross-cutting rules.
# Asserted against the rendered skill, which is what a consuming repo receives.

load helpers/render
load helpers/platforms

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

@test "to-issues slice rules: behaviours observable at the highest existing seam; thinnest first slice only when split" {
  grep -qF 'externally observable' "$SKILL_FILE"
  grep -qF 'highest existing seam' "$SKILL_FILE"
  grep -qiE 'schema / API / UI.*(only )?(as )?an example|example.*schema / API / UI' "$SKILL_FILE"
  rules=$(awk '/<vertical-slice-rules>/{f=1;next} /<\/vertical-slice-rules>/{f=0} f' "$SKILL_FILE")
  echo "$rules" | grep -qE '^- If the work is split, the first slice is the thinnest end-to-end path'
  ! echo "$rules" | grep -qE '^- The first slice is the thinnest'
}

@test "to-issues size rules (D6): no 3-8 target, no merge rule; over 10 criteria is a context-budget check, never a split rule" {
  grep -qF 'single fresh context window' "$SKILL_FILE"
  ! grep -qF 'Prefer many thin slices' "$SKILL_FILE"
  ! grep -qiE 'share a test seam' "$SKILL_FILE"
  ! grep -qiE 'neither is reviewable or demoable alone' "$SKILL_FILE"
  ! grep -qE '3(–|-)8 acceptance criteria' "$SKILL_FILE"
  rules=$(awk '/<vertical-slice-rules>/{f=1;next} /<\/vertical-slice-rules>/{f=0} f' "$SKILL_FILE")
  echo "$rules" | grep -qE 'more than 10 acceptance criteria.*context-budget check.*never.*rule to split'
}

@test "to-issues quiz: ordered outlier list then one approve/adjust prompt; the five generic questions are gone" {
  local a b c d e g
  a=$(grep -n 'Contradicted assumptions' "$SKILL_FILE" | head -1 | cut -d: -f1)
  b=$(grep -n "PRD's \`## Assumptions\`" "$SKILL_FILE" | head -1 | cut -d: -f1)
  c=$(grep -n 'PRD IDs no slice covers' "$SKILL_FILE" | head -1 | cut -d: -f1)
  d=$(grep -n 'Slices over 10 criteria' "$SKILL_FILE" | head -1 | cut -d: -f1)
  e=$(grep -n 'Splits and edges' "$SKILL_FILE" | head -1 | cut -d: -f1)
  g=$(grep -n 'HITL choices' "$SKILL_FILE" | head -1 | cut -d: -f1)
  # One check per line: bats fails only on the last command of an && list, so a chained
  # empty match here passed silently.
  [ -n "$a" ]
  [ -n "$b" ]
  [ -n "$c" ]
  [ -n "$d" ]
  [ -n "$e" ]
  [ -n "$g" ]
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
  [ "$c" -lt "$d" ]
  [ "$d" -lt "$e" ]
  [ "$e" -lt "$g" ]
  ! grep -q 'Slices outside the criteria range' "$SKILL_FILE"
  ! grep -q 'Edges and merges the edge rule produced' "$SKILL_FILE"
  grep -qF 'node "$TRACKER" fetch <ref> --comments' "$SKILL_FILE"
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
  pub=$(grep -n 'node "$TRACKER" publish-issues' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ "$lint" -lt "$pub" ]
}

@test "to-issues: the lint run takes known's output as --known and drafts name blockers by filename, for every tracker" {
  grep -qF 'node "$TRACKER" known --feature-slug <feature-slug> --out .scratch/<feature-slug>/.drafts/known' "$SKILL_FILE"
  grep -qF 'Pass every file `known` wrote as a `--known <file>`' "$SKILL_FILE"
  grep -qF 'The CLI turns each draft filename into the ref its issue is created under' "$SKILL_FILE"
}

@test "to-issues: the shared-file WARN is advisory, never by itself grounds for a Blocked by edge" {
  grep -qF 'The shared-file `WARN` (two issues naming the same file with no `## Blocked by` path between them) is advisory: it is never by itself grounds for a `Blocked by` edge — only the edge rule'"'"'s rows 1–2 are' "$SKILL_FILE"
}

@test "to-issues: the feature's existing issues are --known files whose Implements count toward coverage" {
  grep -qF 'node "$TRACKER" known --feature-slug <feature-slug>' "$SKILL_FILE"
  grep -qF 'an existing `--known` file'"'"'s `## Implements` counts toward `--prd` coverage' "$SKILL_FILE"
  run grep -qF 'never opened' "$SKILL_FILE"
  [ "$status" -ne 0 ]
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

@test "to-issues step 1 reads a referenced issue's comments via the CLI's fetch --comments" {
  grep -qF 'node "$TRACKER" fetch <ref> --comments' "$SKILL_FILE"
}

@test "github tracker template lists the CLI's fetch op" {
  grep -q '^node "$TRACKER" fetch <number> \[--comments\]' "$SCRIPT_DIR/tracker/docs/github.md"
}

# --- Merge by default, split reasons, edge rule, overhead, quiz items, anchored on the skill's own headings ---

step4() { awk '/^### 4\. Draft vertical slices/{f=1;next} /^### /{f=0} f' "$SKILL_FILE"; }
quiz() { awk '/^### 5\. Quiz/{f=1;next} /^### /{f=0} f' "$SKILL_FILE"; }

@test "to-issues D1/B1: step 4 starts from one slice for the whole PRD and splits only for a named reason" {
  section=$(step4)
  echo "$section" | head -5 | grep -qF 'Start from **one slice for the whole PRD**'
  echo "$section" | grep -qiF 'name the reason on every split'
}

@test "to-issues D2: the four split reasons, each named, in order; unrelated modules or seams are not one" {
  section=$(step4)
  reasons=$(echo "$section" | awk '/^Start from \*\*one slice/{f=1;next} f && /^[0-9]+\. /{print} f && /^[^0-9]/ && n++>1{exit}')
  [ "$(echo "$reasons" | wc -l | tr -d ' ')" = 4 ]
  echo "$reasons" | sed -n 1p | grep -q '^1\. \*\*Context budget\*\* — one coder cannot hold it in one fresh session'
  echo "$reasons" | sed -n 2p | grep -q '^2\. \*\*Human boundary\*\* — part is HITL, the rest AFK'
  echo "$reasons" | sed -n 3p | grep -q '^3\. \*\*Parallelism worth having\*\* — both halves are large and independent'
  echo "$reasons" | sed -n 3p | grep -q 'a half of a few criteria does not qualify'
  echo "$reasons" | sed -n 4p | grep -q "^4\. \*\*Expand–contract order\*\* — .*\`## Compatibility & Migration\`.*\`references/expand-contract.md\`.*must land in sequence"
  echo "$section" | grep -qi 'unrelated modules or test seams are not a reason on their own'
}

@test "to-issues D3: context budget is anchored to the crew-afk-review reference size, no line limit" {
  section=$(step4)
  echo "$section" | grep -qF '#148–#160: 7–44 files, ~100–1600 lines'
  echo "$section" | grep -qi 'no line limit'
}

@test "to-issues D4: edge rule has only the two Blocked by rows, between split slices; row 3, the parallel row and first-match are gone" {
  section=$(step4)
  echo "$section" | grep -q '^\*\*Edge rule\.\*\* Between slices that remain split'
  rows=$(echo "$section" | awk '/^\*\*Edge rule\.\*\*/{f=1;next} f && /^[0-9]+\. /{print} f && /^$/ && n++>0{exit}')
  [ "$(echo "$rows" | wc -l | tr -d ' ')" = 2 ]
  echo "$rows" | sed -n 1p | grep -q '^1\. One slice consumes what the other produces.*`Blocked by`'
  echo "$rows" | sed -n 2p | grep -q '^2\. The two change the same meaning.*`Blocked by`'
  ! echo "$section" | grep -q 'first match wins'
  ! echo "$section" | grep -q 'same small file'
  ! echo "$section" | grep -q 'Anything else'
  echo "$section" | grep -qi 'parallelism worth having.*never.*edge\|never yields an edge'
}

@test "to-issues D8: overhead sentence precedes the edge rule and names the serial-round cost of an edge" {
  section=$(step4)
  echo "$section" | grep -q 'Every slice costs fixed overhead before and after its code: a worktree, a deps install, a coder dispatch, verify, review and merge'
  echo "$section" | grep -q 'Every `Blocked by` edge also adds a serial round'
  o=$(echo "$section" | grep -n 'Every slice costs fixed overhead' | cut -d: -f1)
  e=$(echo "$section" | grep -n 'Edge rule\.' | cut -d: -f1)
  [ "$o" -lt "$e" ]
}

@test "to-issues D6: quiz item 5 lists slices over 10 criteria or ~200k estimated tokens as a context-budget check" {
  quiz | grep -q '^5\. \*\*Slices over 10 criteria or ~200k tokens\*\* — .*more than 10 acceptance criteria.*context-budget check'
  quiz | grep '^5\. ' | grep -qF '~200k tokens'
  quiz | grep '^5\. ' | grep -qF "the coder model's window when smaller"
  quiz | grep '^5\. ' | grep -qF 'never on its own a rule to split'
}

@test "to-issues step 4's context-budget reason gives the estimate method and compares it with the coder's window" {
  local r1; r1=$(step4 | grep '^1\. \*\*Context budget\*\*')
  for part in 'bytes' '÷ ~3.5' 'fixed context every coder dispatch loads' 'measured' 'margin' "coder model's context window"; do
    grep -qF -- "$part" <<<"$r1" || { echo "context-budget reason lacks: $part" >&2; return 1; }
  done
}

@test "to-issues step 5 shows each slice's estimated peak context" {
  quiz | grep -qF -- '- **Estimated peak context**'
}

@test "to-issues D7/B2: quiz item 6 lists each split with its reason and each edge with its row; the seam-count item is gone" {
  q=$(quiz)
  echo "$q" | grep -q '^6\. \*\*Splits and edges\*\* — one line per split naming its reason from step 4'
  echo "$q" | grep -q 'one line per `Blocked by` edge naming the edge-rule row'
  echo "$q" | grep -q "Don't ask whether an overlap needs an edge"
  ! echo "$q" | grep -q 'Seam count'
  ! echo "$q" | grep -q 'distinct seams'
  echo "$q" | grep -q '^7\. \*\*HITL choices\*\*'
}

@test "the PRD coverage table exempts an ID whose line ends in (no slice)" {
  sed -n '/^### 4.5/,/^### 5\./p' "$SKILL_FILE" | grep -q '(no slice)'
}

@test "to-issues sends a criterion needing a paid run, a manual measurement or a person to the PRD's human steps or a ready-for-human issue, for every platform" {
  local p
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    grep -qF 'A criterion that needs a paid run, a manual measurement or a person is not an acceptance criterion' "$output"
    grep -qF "It goes to the PRD's human steps or a \`ready-for-human\` issue" "$output"
  done
}
