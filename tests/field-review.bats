#!/usr/bin/env bats

# scripts/field-review.mjs — two crew-review versions on another project's range, blind. Runs against a
# throwaway coding-crew repo and project, with a fake `claude` on CLAUDE_BIN, so it costs nothing.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  R="$T/crew"
  mkdir -p "$R/scripts" "$R/skills/crew-review"
  cp "$REPO_ROOT/scripts/eval-design-skills.mjs" "$REPO_ROOT/scripts/field-review.mjs" "$R/scripts/"
  echo "SKILL-V1" > "$R/skills/crew-review/SKILL.md"
  git -C "$R" init -q -b main
  git -C "$R" -c user.email=t@t -c user.name=t add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm one
  echo "SKILL-V2" > "$R/skills/crew-review/SKILL.md"
  git -C "$R" -c user.email=t@t -c user.name=t commit -qam two
  git -C "$R" branch v1 HEAD~1

  P="$T/proj"
  mkdir -p "$P/tests"
  echo '{}' > "$P/package.json"; echo x > "$P/tests/a.test.js"
  git -C "$P" init -q -b main
  git -C "$P" -c user.email=t@t -c user.name=t add -A
  git -C "$P" -c user.email=t@t -c user.name=t commit -qm base
  PB=$(git -C "$P" rev-parse HEAD)
  echo y > "$P/b.js"
  git -C "$P" -c user.email=t@t -c user.name=t add -A
  git -C "$P" -c user.email=t@t -c user.name=t commit -qm head
  PH=$(git -C "$P" rev-parse HEAD)
  echo "the spec" > "$T/spec.md"

  # Fake claude: logs each prompt to prompts.txt, prints a report with one finding.
  # FAKE_DIRTY=<text> writes a file into its cwd when its prompt contains <text>.
  cat > "$T/claude" <<'EOS'
#!/usr/bin/env bash
input=$(cat)
printf '%s\n---\n' "$input" >> "$FAKE_DIR/prompts.txt"
if [ -n "${FAKE_DIRTY:-}" ] && [[ "$input" == *"$FAKE_DIRTY"* ]]; then echo x > stray.txt; fi
jq -n --arg r $'Reviewed.\n```json\n{"spec":"met","gaps":[],"findings":[{"severity":"HIGH","location":"b.js:1","issue":"breaks","fix":"f"}]}\n```' '{result:$r,total_cost_usd:0.25,is_error:false}'
EOS
  chmod +x "$T/claude"
  export CLAUDE_BIN="$T/claude" FAKE_DIR="$T" EVAL_RETRY_MS=0
}

teardown() {
  rm -rf "$T"
}

run_field() { (cd "$R" && node scripts/field-review.mjs "$P" --range "$PB..$PH" --out "$T/out" "$@"); }
out_dir() { echo "$T/out/proj/"*; }

@test "two blind reviews: meta, both outputs, a key, a verdict sheet and a misses file; no worktree left behind" {
  run run_field --spec "$T/spec.md" --skill-base v1 --skill-head main
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  d=$(out_dir)
  for f in meta.json A.out.md B.out.md key.json verdicts.md misses.md spec.md; do [ -f "$d/$f" ] || { echo "no $f"; return 1; }; done
  jq -e --arg b "$PB" --arg h "$PH" '.base == $b and .head == $h and .type.manifests == ["package.json"] and .type.hasTests' "$d/meta.json" >/dev/null
  jq -e '[.runs[] | select(.ok and .cost == 0.25 and .findings == 1)] | length == 2' "$d/meta.json" >/dev/null
  jq -e '[.[]] | sort == ["base", "head"]' "$d/key.json" >/dev/null
  [ "$(grep -c '^- verdict: ___ — HIGH `b.js:1` — breaks$' "$d/verdicts.md")" -eq 2 ]
  ! grep -qE 'base|head' "$d/verdicts.md" || false
  [ "$(git -C "$P" worktree list | wc -l)" -eq 1 ]
  [ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]
}

@test "each reviewer follows its own version's SKILL.md, on the range, against the copied spec" {
  run run_field --spec "$T/spec.md" --skill-base v1 --skill-head main
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  d=$(out_dir)
  [ "$(grep -c "base $PB" "$T/prompts.txt")" -eq 2 ]
  [ "$(grep -c "against the spec in $d/spec.md" "$T/prompts.txt")" -eq 2 ]
  grep -q 'skill-base/skills/crew-review/SKILL.md' "$T/prompts.txt"
  grep -q 'skill-head/skills/crew-review/SKILL.md' "$T/prompts.txt"
  jq -e --arg v1 "$(git -C "$R" rev-parse v1)" '.skills[0].sha == $v1' "$d/meta.json" >/dev/null
}

@test "with no spec, the reviewers skip question 1" {
  run run_field
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'with no spec (skip question 1)' "$T/prompts.txt")" -eq 2 ]
}

@test "a reviewer that changes its worktree is a failed run, and the script exits 1" {
  FAKE_DIRTY=skill-head run run_field --skill-base v1 --skill-head main
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  d=$(out_dir)
  jq -e '[.runs[] | select(.ok | not)] | length == 1' "$d/meta.json" >/dev/null
  grep -q 'Run failed: changed its worktree' "$d/verdicts.md"
}

@test "a dry run writes the prompts and calls no model" {
  run run_field --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -f "$T/prompts.txt" ]
  [ -f "$(out_dir)/base.prompt.md" ] && [ -f "$(out_dir)/head.prompt.md" ]
}

@test "an existing output folder is refused rather than overwritten" {
  run run_field --dry-run
  run run_field --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"already exists: move it aside or pass --out"* ]] || { echo "$output"; return 1; }
}
