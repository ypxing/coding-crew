#!/usr/bin/env bats

# scripts/eval-design-skills.mjs — the behavioural A/B harness for crew-grill / crew-brainstorm / to-issues.
# Runs against a throwaway repo with a fake `claude` on CLAUDE_BIN, so it costs nothing: it
# checks the run matrix, that the judge is blind to which version wrote what, and the summary.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  R="$T/repo"
  mkdir -p "$R/scripts/eval-design-skills/cases" "$R/skills/crew-grill" "$R/skills/to-issues"
  cp "$REPO_ROOT/scripts/eval-design-skills.mjs" "$R/scripts/"
  echo "RUBRIC-TEXT" > "$R/scripts/eval-design-skills/rubric.md"
  echo "TO-ISSUES-RUBRIC-TEXT" > "$R/scripts/eval-design-skills/rubric-to-issues.md"
  echo "SKILL-V1-SECRET" > "$R/skills/crew-grill/SKILL.md"
  echo "SKILL-V1-SECRET to-issues" > "$R/skills/to-issues/SKILL.md"
  git -C "$R" init -q -b main
  git -C "$R" -c user.email=t@t -c user.name=t add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm init
  REF=$(git -C "$R" rev-parse --short HEAD)
  cat > "$R/scripts/eval-design-skills/cases/c1.md" <<EOF
---
skill: crew-grill
stage: round1
repo_ref: $REF
---
## Request
Do the thing.

## Reference judgement
Small is right.
EOF
  echo "SKILL-V2-SECRET" > "$R/skills/crew-grill/SKILL.md"   # head = worktree
  echo "SKILL-V2-SECRET to-issues" > "$R/skills/to-issues/SKILL.md"

  # Fake claude: subject runs echo which skill text they got; the judge (--max-turns 1) scores
  # every labelled output and saves its prompt for inspection. FAKE_FAIL=<text> fails a subject
  # run whose prompt contains <text>.
  cat > "$T/claude" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
if [[ " $* " == *" --max-turns 1 "* ]]; then
  printf '%s' "$input" > "$FAKE_DIR/judge-prompt.txt"
  printf '%s\n=== END JUDGE ===\n' "$input" >> "$FAKE_DIR/judge-prompts.log"
  labels=$(printf '%s\n' "$input" | sed -n 's/^### Output \([A-Z]\)$/\1/p')
  arr=""; for l in $labels; do
    arr+="${arr:+,}{\"label\":\"$l\",\"scores\":{\"sized\":1,\"do_least\":null,\"asked_well\":1,\"overbuilt\":0,\"underbuilt\":0,\"false_cut\":null,\"chain_priced\":null,\"count_ok\":1,\"splits_justified\":1,\"overmerged\":0,\"oversplit\":null},\"note\":\"ok\"}"
  done
  jq -n --arg r "[$arr]" '{result:$r,total_cost_usd:0.5,is_error:false}'
  exit 0
fi
if [ -n "${FAKE_FAIL:-}" ] && [[ "$input" == *"$FAKE_FAIL"* ]]; then
  echo '{"result":"boom","total_cost_usd":0.1,"is_error":true}'; exit 1
fi
v=$(printf '%s' "$input" | grep -o 'SKILL-V[12]-SECRET' | head -1)
jq -n --arg r "output from $v" '{result:$r,total_cost_usd:0.25,is_error:false}'
EOF
  chmod +x "$T/claude"
  export CLAUDE_BIN="$T/claude" FAKE_DIR="$T"
}

teardown() {
  rm -rf "$T"
}

run_eval() {
  (cd "$R" && node scripts/eval-design-skills.mjs "$@")
}

@test "dry run prints the matrix: cases x 2 versions x runs" {
  run run_eval --dry-run --runs 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"6 subject runs (1 cases × 2 versions × 3)"* ]]
  [ "$(grep -c '  c1 ' <<<"$output")" -eq 6 ]
}

@test "base reads the committed skill, head reads the worktree" {
  run run_eval --runs 1
  [ "$status" -eq 0 ]
  d=$(ls -d "$R"/.scratch/eval-design-skills/*/)
  grep -q 'SKILL-V1-SECRET' "$d/c1-base-1.out.md"
  grep -q 'SKILL-V2-SECRET' "$d/c1-head-1.out.md"
}

@test "the judge is blind: no version names, no skill text, rubric and reference included" {
  run run_eval --runs 2
  [ "$status" -eq 0 ]
  p="$T/judge-prompt.txt"
  grep -q 'RUBRIC-TEXT' "$p"
  grep -q 'Small is right.' "$p"
  [ "$(grep -c '^### Output [A-D]$' "$p")" -eq 4 ]
  ! grep -qi 'base\|head\|SKILL-V[12]-SECRET' <(grep -v '^output from' "$p")
}

@test "summary scores each version, sums cost, and removes the worktree" {
  run run_eval --runs 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"| c1 | base | 2 | 2/2 | n/a | 2/2 | 0/2 | 0/2 | n/a | n/a | \$0.50 |"* ]]
  [[ "$output" == *"| c1 | head | 2 | 2/2 | n/a | 2/2 | 0/2 | 0/2 | n/a | n/a | \$0.50 |"* ]]
  [[ "$output" == *'Total cost: $1.50'* ]]
  [ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]
}

@test "a failed subject run is reported, not judged" {
  FAKE_FAIL=SKILL-V2-SECRET run run_eval --runs 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"c1-head-1: FAILED"* ]]
  [ "$(grep -c '^### Output' "$T/judge-prompt.txt")" -eq 1 ]
  d=$(ls -d "$R"/.scratch/eval-design-skills/*/)
  grep -q 'c1 head #1: run failed' "$d/summary.md"
}

@test "a case without a reference judgement is rejected" {
  printf -- '---\nskill: crew-grill\nstage: round1\nrepo_ref: x\n---\n## Request\nx\n' \
    > "$R/scripts/eval-design-skills/cases/bad.md"
  run run_eval --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad: needs ## Request and ## Reference judgement"* ]]
}

@test "every committed case parses" {
  # Paths go through env, not argv: the script runs main() when argv[1] is its own path.
  run env MOD="$REPO_ROOT/scripts/eval-design-skills.mjs" DIR="$REPO_ROOT/scripts/eval-design-skills/cases" node -e '
    import(process.env.MOD).then((m) => {
      const fs = require("fs"), dir = process.env.DIR;
      for (const f of fs.readdirSync(dir)) m.parseCase(f, fs.readFileSync(`${dir}/${f}`, "utf8"));
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
}

@test "a claude binary that cannot be spawned fails its runs, not the whole matrix" {
  # Seen live: claude's auto-updater replaced the binary mid-run, spawn threw ENOENT, and the
  # unhandled error killed the process and leaked the worktree.
  CLAUDE_BIN="$T/no-such-claude" EVAL_RETRY_MS=0 run run_eval --runs 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"c1-base-1: FAILED"* ]]
  [[ "$output" == *"c1-head-1: FAILED"* ]]
  [ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]
}

@test "a usage limit stops the evaluation: exit 3, later runs skipped, nothing judged" {
  # Seen live: a session limit turned 45 of 60 runs into identical empty failures and the
  # matrix "finished". It must stop and say what was done.
  cat > "$T/limited" <<'EOS'
#!/usr/bin/env bash
cat >/dev/null
echo '{"result":"You'"'"'ve hit your session limit · resets 1:50am (UTC)","total_cost_usd":0,"is_error":true}'
exit 1
EOS
  chmod +x "$T/limited"
  CLAUDE_BIN="$T/limited" run run_eval --runs 2 --parallel 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"STOPPED"* ]]
  [[ "$output" == *"session limit"* ]]
  [ ! -e "$T/judge-prompt.txt" ]
  [ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]
  # --parallel 1: the first run hits the limit, the other three never start
  [ "$(grep -c 'LIMIT' <<<"$output")" -eq 1 ]
}

@test "an API throttle is retried, then succeeds" {
  # Seen live: parallel runs hit "Too many requests" and 9 of 60 runs failed for a reason that
  # a pause fixes.
  cat > "$T/flaky" <<'EOS'
#!/usr/bin/env bash
input=$(cat)
if [[ " $* " == *" --max-turns 1 "* ]]; then
  echo '{"result":"[]","total_cost_usd":0,"is_error":false}'; exit 0
fi
n=$(cat "$FAKE_DIR/count" 2>/dev/null || echo 0); echo $((n+1)) > "$FAKE_DIR/count"
if [ "$n" -lt 2 ]; then
  echo '{"result":"API Error: Too many requests sent to ApplyGuardrail","total_cost_usd":0,"is_error":true}'; exit 1
fi
echo '{"result":"fine","total_cost_usd":0.1,"is_error":false}'
EOS
  chmod +x "$T/flaky"
  CLAUDE_BIN="$T/flaky" EVAL_RETRY_MS=0 run run_eval --runs 1 --parallel 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"c1-base-1: ok"* ]]
  [ "$(cat "$T/count")" -ge 3 ]
}

# --- to-issues: the slice stage, per-skill rubric and metrics ---

add_slice_case() {
  cat > "$R/scripts/eval-design-skills/cases/s1.md" <<EOF
---
skill: to-issues
stage: slice
repo_ref: $REF
---
## Request
PRD: build the widget.

## Reference judgement
One slice is right.
EOF
}

@test "a to-issues slice case runs at base and head; its prompt ends with the slice-stage instruction" {
  add_slice_case
  run run_eval --skill to-issues --runs 1
  [ "$status" -eq 0 ]
  d=$(ls -d "$R"/.scratch/eval-design-skills/*/)
  grep -q 'SKILL-V1-SECRET to-issues' "$d/s1-base-1.prompt.txt"
  grep -q 'SKILL-V2-SECRET to-issues' "$d/s1-head-1.prompt.txt"
  grep -q 'SKILL-V1-SECRET' "$d/s1-base-1.out.md"
  last=$(tail -n 1 "$d/s1-head-1.prompt.txt")
  [[ "$last" == "EVAL MODE"* ]]
  [[ "$last" == *"step 5 breakdown"* ]]
  [[ "$last" == *"title"*"criteria count"*"Blocked by"*"split reason"* ]]
  [[ "$last" == *"Then stop."* ]]
  [ ! -e "$d/c1-base-1.prompt.txt" ]
}

@test "a to-issues case is judged on rubric-to-issues.md and its metrics; a grill case keeps rubric.md and METRICS" {
  add_slice_case
  run run_eval --runs 1
  [ "$status" -eq 0 ]
  awk -v t="$T" '/^=== END JUDGE ===$/{n++; next} {print > (t "/jp-" n+0 ".txt")}' "$T/judge-prompts.log"
  sj=$(grep -l 'One slice is right.' "$T"/jp-*.txt)
  gj=$(grep -l 'Small is right.' "$T"/jp-*.txt)
  grep -q 'TO-ISSUES-RUBRIC-TEXT' "$sj"
  ! grep -q '^RUBRIC-TEXT' "$sj"
  grep -q '"count_ok": 0|1|null, "splits_justified": 0|1|null, "overmerged": 0|1|null, "oversplit": 0|1|null' "$sj"
  ! grep -q '"sized"' "$sj"
  grep -q '^RUBRIC-TEXT' "$gj"
  ! grep -q 'TO-ISSUES-RUBRIC-TEXT' "$gj"
  grep -q '"sized": 0|1|null' "$gj"
  ! grep -q 'count_ok' "$gj"
  [[ "$output" == *"| case | version | n | count_ok | splits_justified | overmerged | oversplit | cost |"* ]]
  [[ "$output" == *"| s1 | head | 1 | 1/1 | 1/1 | 0/1 | n/a | \$0.25 |"* ]]
  [[ "$output" == *"| case | version | n | sized | do_least | asked_well | overbuilt | underbuilt | false_cut | chain_priced | cost |"* ]]
  [[ "$output" == *"| c1 | head | 1 | 1/1 | n/a | 1/1 | 0/1 | 0/1 | n/a | n/a | \$0.25 |"* ]]
}

@test "a case whose skill has no metric list is rejected, naming the case" {
  printf -- '---\nskill: write-pr\nstage: round1\nrepo_ref: x\n---\n## Request\nx\n\n## Reference judgement\ny\n' \
    > "$R/scripts/eval-design-skills/cases/nometrics.md"
  run run_eval --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"nometrics: "*"write-pr"*"metric"* ]]
}

@test "the committed to-issues cases dry-run as 3 cases x 2 versions x runs" {
  run bash -c "cd '$REPO_ROOT' && node scripts/eval-design-skills.mjs --skill to-issues --dry-run --runs 2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"12 subject runs (3 cases × 2 versions × 2)"* ]]
  for c in slice-review-catches slice-promote-after-merge slice-crew-afk-review; do
    [ "$(grep -c "  $c " <<<"$output")" -eq 4 ]
  done
}

@test "the committed to-issues cases pin repo_ref to a commit and use the slice stage" {
  for c in slice-review-catches slice-promote-after-merge slice-crew-afk-review; do
    f="$REPO_ROOT/scripts/eval-design-skills/cases/$c.md"
    grep -q '^skill: to-issues$' "$f"
    grep -q '^stage: slice$' "$f"
    ref=$(sed -n 's/^repo_ref: //p' "$f")
    git -C "$REPO_ROOT" cat-file -e "$ref^{commit}"
  done
}

@test "a Request that inlines a PRD keeps the PRD's own ## headings" {
  run env MOD="$R/scripts/eval-design-skills.mjs" node -e '
    import(process.env.MOD).then((m) => {
      const c = m.parseCase("p", "---\nskill: to-issues\nstage: slice\nrepo_ref: x\n---\n## Request\nPRD:\n\n## Decisions\n\n- **D1** — x\n\n## Compatibility & Migration\n\nnone\n\n## Reference judgement\nTwo slices.\n");
      console.log(JSON.stringify(c.request)); console.log(c.reference);
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'## Decisions\n\n- **D1** — x\n\n## Compatibility & Migration\n\nnone"'* ]]
  [[ "$output" == *"Two slices."* ]]
}
