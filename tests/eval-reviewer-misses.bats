#!/usr/bin/env bats

# scripts/eval-reviewer-misses.mjs — the replay eval for reviewer misses. Runs against a throwaway
# repo (a copy of this repo's orchestrator/) with a fake `claude` on CLAUDE_BIN, so it costs nothing.
# Also the rendered reviewer role and to-prd SKILL.md this eval's change is about.

load helpers/render

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  R="$T/repo"
  mkdir -p "$R/scripts/eval-reviewer-misses/cases" "$R/skills"
  cp "$REPO_ROOT/scripts/eval-design-skills.mjs" "$REPO_ROOT/scripts/eval-reviewer-misses.mjs" "$R/scripts/"
  cp "$REPO_ROOT/scripts/eval-reviewer-misses/build-prompts.mjs" "$R/scripts/eval-reviewer-misses/"
  echo "RUBRIC-TEXT" > "$R/scripts/eval-reviewer-misses/rubric.md"
  cp -R "$REPO_ROOT/orchestrator" "$R/orchestrator"
  cp -R "$REPO_ROOT/skills/_shared" "$R/skills/_shared"
  echo "PROTO-V1" >> "$R/orchestrator/roles/reviewer.md"
  git -C "$R" init -q -b main
  git -C "$R" -c user.email=t@t -c user.name=t add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm one
  C1=$(git -C "$R" rev-parse HEAD)
  sed -i.bak 's/PROTO-V1/PROTO-V2/' "$R/orchestrator/roles/reviewer.md"
  rm "$R/orchestrator/roles/reviewer.md.bak"
  git -C "$R" -c user.email=t@t -c user.name=t commit -qam two
  C2=$(git -C "$R" rev-parse HEAD)
  BASEREF="$C1"
  write_case branch-case branch "$C1" "$C2"
  write_case feature-case feature "$C1" "$C2"

  # Fake claude. Judge prompts (they list "Expected misses") score every output as catching m1 and
  # save the prompt; planner prompts answer with no json; anything else is a reviewer, which prints
  # a report with 2 findings. FAKE_FAIL=<text> fails a reviewer whose prompt contains <text>;
  # FAKE_JUDGE_FAIL=1 fails the judge; FAKE_FORBID=1 fails and leaves a flag when called at all.
  cat > "$T/claude" <<'EOS'
#!/usr/bin/env bash
input=$(cat)
if [ -n "${FAKE_FORBID:-}" ]; then touch "$FAKE_DIR/called"; exit 1; fi
if [[ "$input" == *"## Expected misses"* ]]; then
  printf '%s' "$input" > "$FAKE_DIR/judge-prompt.txt"
  [ -n "${FAKE_JUDGE_FAIL:-}" ] && { echo '{"result":"boom","total_cost_usd":0.1,"is_error":true}'; exit 1; }
  labels=$(printf '%s\n' "$input" | sed -n 's/^### Output \([A-Z]\)$/\1/p')
  arr=""; for l in $labels; do
    d=1
    if [ -n "${FAKE_BASE_EMPTY:-}" ]; then d=$(printf '%s\n' "$input" | awk -v l="$l" '/^### Output /{on=($3==l)} on&&/"severity"/{n++} END{print n+0}'); fi
    arr+="${arr:+,}{\"label\":\"$l\",\"caught\":{\"m1\":true},\"distinct\":$d,\"note\":\"ok\"}"
  done
  jq -n --arg r "[$arr]" '{result:$r,total_cost_usd:0.5,is_error:false}'; exit 0
fi
if [[ "$input" == *"Feature review planning"* ]]; then
  jq -n '{result:"no plan",total_cost_usd:0.1,is_error:false}'; exit 0
fi
if [ -n "${FAKE_FAIL:-}" ] && [[ "$input" == *"$FAKE_FAIL"* ]]; then
  echo '{"result":"boom","total_cost_usd":0.1,"is_error":true}'; exit 1
fi
if [ -n "${FAKE_BASE_EMPTY:-}" ] && [[ "$input" == *PROTO-V1* ]]; then
  jq -n --arg r $'Reviewed.\n```json\n{"findings":[]}\n```' '{result:$r,total_cost_usd:0.25,is_error:false}'; exit 0
fi
jq -n --arg r $'Reviewed.\n```json\n{"findings":[{"severity":"HIGH"},{"severity":"LOW"}]}\n```' '{result:$r,total_cost_usd:0.25,is_error:false}'
EOS
  chmod +x "$T/claude"
  export CLAUDE_BIN="$T/claude" FAKE_DIR="$T" EVAL_RETRY_MS=0
}

teardown() {
  rm -r "$T"
}

write_case() { # name mode base head
  cat > "$R/scripts/eval-reviewer-misses/cases/$1.md" <<EOC
---
mode: $2
base_sha: $3
head_sha: $4
slug: feat
via: origin/feature/x
---
Replay of a change.

## Issue

01-thing

## Implements

D1

## Acceptance criteria

- [ ] The thing is done.

## Expected misses

- m1: the unchanged helper is now wrong.

## Reference judgement

The helper is wrong after the change.

## PRD

- **D1** — the decision text.
EOC
}

run_eval() {
  (cd "$R" && node scripts/eval-reviewer-misses.mjs --base "$BASEREF" --head main "$@")
}

out_dir() { ls -d "$R"/.scratch/eval-reviewer-misses/*/ | tail -1; }

@test "dry run lists the cases, writes each ref's prompts, and calls no model" {
  FAKE_FORBID=1 run run_eval --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch-case"* ]]
  [[ "$output" == *"feature-case"* ]]
  [ ! -e "$T/called" ]
  d=$(out_dir)
  for f in branch-case-base.feat.prompt.md branch-case-head.feat.prompt.md \
           feature-case-base.feature-1.prompt.md feature-case-head.feature-1.prompt.md; do
    [ -s "$d/$f" ]
  done
  grep -q 'the decision text' "$d/branch-case-head.feat.prompt.md"
}

@test "each ref's prompts carry that ref's own protocol text" {
  run run_eval --dry-run
  [ "$status" -eq 0 ]
  d=$(out_dir)
  for c in branch-case:feat feature-case:feature-1; do
    n=${c%%:*}; a=${c##*:}
    grep -q 'PROTO-V1' "$d/$n-base.$a.prompt.md"
    ! grep -q 'PROTO-V2' "$d/$n-base.$a.prompt.md"
    grep -q 'PROTO-V2' "$d/$n-head.$a.prompt.md"
    ! grep -q 'PROTO-V1' "$d/$n-head.$a.prompt.md"
  done
}

@test "a full run writes summary.md and results.json per case and ref; the judge is blind" {
  run run_eval --runs 2
  [ "$status" -eq 0 ]
  d=$(out_dir)
  [ -s "$d/summary.md" ]
  [ "$(jq '[.rows[] | select(.case=="branch-case" and .version=="base" and .caught.m1==true and .findings==2 and .distinct==1)] | length' "$d/results.json")" -eq 2 ]
  [ "$(jq '[.rows[] | select(.case=="feature-case" and .version=="head" and .caught.m1==true and .findings==2)] | length' "$d/results.json")" -eq 2 ]
  grep -q 'm1 2/2' "$d/summary.md"
  p="$T/judge-prompt.txt"
  grep -q 'RUBRIC-TEXT' "$p"
  grep -q 'The helper is wrong after the change.' "$p"
  [ "$(grep -c '^### Output [A-D]$' "$p")" -eq 4 ]
  ! grep -qiE '\b(base|head)\b|PROTO-V' "$p"
  [ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]
}

@test "an unresolvable SHA is named, the other case still runs, exit is non-zero" {
  write_case ghost-case branch deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$C2"
  run run_eval --runs 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNRESOLVED ghost-case"* ]]
  d=$(out_dir)
  [ "$(jq '[.rows[] | select(.case=="branch-case")] | length' "$d/results.json")" -eq 2 ]
  [ "$(jq '[.rows[] | select(.case=="ghost-case")] | length' "$d/results.json")" -eq 0 ]
}

@test "a failed reviewer run is a failed run, never not-caught" {
  FAKE_FAIL=PROTO-V2 run run_eval --runs 1 --case branch-case
  [ "$status" -ne 0 ]
  d=$(out_dir)
  [ "$(jq -r '.rows[] | select(.version=="head") | .ok' "$d/results.json")" = "false" ]
  [ "$(jq -r '.rows[] | select(.version=="head") | .caught' "$d/results.json")" = "null" ]
  [ "$(jq -r '.rows[] | select(.version=="base") | .caught.m1' "$d/results.json")" = "true" ]
  [ "$(grep -c '^### Output' "$T/judge-prompt.txt")" -eq 1 ]
  grep -q 'FAILED' "$d/summary.md"
}

@test "a failed judge leaves every run failed, not not-caught" {
  FAKE_JUDGE_FAIL=1 run run_eval --runs 1 --case branch-case
  [ "$status" -ne 0 ]
  d=$(out_dir)
  [ "$(jq '[.rows[] | select(.caught != null)] | length' "$d/results.json")" -eq 0 ]
  [ "$(jq '[.rows[] | select(.ok == false)] | length' "$d/results.json")" -eq 2 ]
}

@test "every committed case parses" {
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" DIR="$REPO_ROOT/scripts/eval-reviewer-misses/cases" node -e '
    import(process.env.MOD).then((m) => {
      const fs = require("fs"), dir = process.env.DIR;
      const names = fs.readdirSync(dir).map((f) => { m.parseCase(f, fs.readFileSync(`${dir}/${f}`, "utf8")); return f; });
      for (const n of ["promote-after-merge-feature.md", "promote-after-merge-207.md"]) if (!names.includes(n)) throw new Error(`missing ${n}`);
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
}

# The rendered reviewer role

role() {
  (cd "$REPO_ROOT" && node --input-type=module -e '
    import { renderRolePrompt } from "./orchestrator/lib/adapters/render.mjs";
    process.stdout.write(renderRolePrompt("reviewer", "claude"));')
}

@test "the reviewer role opens with the goal-first question" {
  first=$(role | grep -m1 '^## ')
  [ "$first" = "## The Question" ]
  role | sed -n '/^## The Question/,/^## What You Receive/p' | grep -q 'what does it break'
}

@test "the reviewer role puts affected unchanged code in scope and reads callees and state" {
  r=$(role)
  grep -q 'unchanged code whose correctness the' <<<"$r"
  grep -q 'at any severity' <<<"$r"
  grep -qi 'callers' <<<"$r"
  grep -q 'what it calls' <<<"$r"
  grep -q 'state it' <<<"$r"
}

@test "the reviewer role no longer limits unchanged code to CRITICAL classes or presents triage as a filter" {
  r=$(role)
  ! grep -q 'directly triggers a CRITICAL' <<<"$r"
  ! grep -q '>80% confident' <<<"$r"
  ! grep -qi 'triage' <<<"$r"
}

@test "to-prd requires cited facts for what relies on a changed behaviour" {
  f="$(rendered_skill to-prd claude)"
  grep -q 'callers' "$f"
  grep -q 'state it reads or writes' "$f"
  grep -q 'older' "$f"
  grep -q 'is not a fact' "$f"
}

@test "the judge is asked for distinct findings, the summary names the models and gives both means" {
  run run_eval --runs 1
  d=$(out_dir)
  grep -q '"distinct"' "$T/judge-prompt.txt"
  grep -q 'Reviewers on opus, judge on opus' "$d/summary.md"
  grep -q 'mean findings (raw) | mean findings (distinct)' "$d/summary.md"
  [ "$(jq -r .model "$d/results.json")" = opus ]
}

@test "a base mean of 0 against a head above 0 reports the increase, not n/a" {
  run env FAKE_BASE_EMPTY=1 bash -c "cd '$R' && node scripts/eval-reviewer-misses.mjs --base '$BASEREF' --head main --runs 1"
  [ "$status" -eq 0 ]
  d=$(out_dir)
  grep -q 'branch-case inf (base 0, head 1.0)' "$d/summary.md"
  ! grep -q 'branch-case n/a' "$d/summary.md"
}

@test "formatRatio tells a base mean of 0 from a missing mean" {
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" node -e '
    import(process.env.MOD).then((m) => {
      const a = m.formatRatio(0, 0.5), b = m.formatRatio(null, 1), c = m.formatRatio(2, 3), d = m.formatRatio(0, 0);
      if (!a.startsWith("inf") || b !== "n/a" || c !== "1.50x" || d === "inf" || !d.startsWith("n/a")) throw new Error([a, b, c, d].join("|"));
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
}

@test "an API rate limit is retried, not recorded" {
  cat > "$T/flaky" <<'EOS'
#!/usr/bin/env bash
n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0); echo $((n+1)) > "$FAKE_DIR/n"
if [ "$n" -lt 2 ]; then echo '{"result":"API Error: rate limit exceeded (ApplyGuardrail throttled)","total_cost_usd":0,"is_error":true}'; exit 1; fi
exec "$FAKE_DIR/claude"
EOS
  chmod +x "$T/flaky"
  CLAUDE_BIN="$T/flaky" run run_eval --runs 1 --case branch-case
  [ "$status" -eq 0 ]
  [ "$(cat "$T/n")" -gt 2 ]
}
