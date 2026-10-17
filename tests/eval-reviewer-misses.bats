#!/usr/bin/env bats

# scripts/eval-reviewer-misses.mjs — the replay eval for crew-review's misses. Runs against a throwaway
# repo with its own skills/crew-review/SKILL.md and a fake `claude` on CLAUDE_BIN, so it costs nothing.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  R="$T/repo"
  mkdir -p "$R/scripts/eval-reviewer-misses/cases" "$R/skills"
  cp "$REPO_ROOT/scripts/eval-design-skills.mjs" "$REPO_ROOT/scripts/eval-reviewer-misses.mjs" "$R/scripts/"
  cp "$REPO_ROOT/scripts/eval-reviewer-misses/build-prompts.mjs" "$R/scripts/eval-reviewer-misses/"
  echo "RUBRIC-TEXT" > "$R/scripts/eval-reviewer-misses/rubric.md"
  mkdir -p "$R/skills/crew-review"
  echo "PROTO-V1" > "$R/skills/crew-review/SKILL.md"
  git -C "$R" init -q -b main
  git -C "$R" -c user.email=t@t -c user.name=t add -A
  git -C "$R" -c user.email=t@t -c user.name=t commit -qm one
  C1=$(git -C "$R" rev-parse HEAD)
  echo "PROTO-V2" > "$R/skills/crew-review/SKILL.md"
  git -C "$R" -c user.email=t@t -c user.name=t commit -qam two
  C2=$(git -C "$R" rev-parse HEAD)
  BASEREF="$C1"
  write_case branch-case branch "$C1" "$C2"
  write_case feature-case feature "$C1" "$C2"

  # Fake claude. Judge prompts (they list "Expected misses") score every output as catching m1 and
  # save the prompt; anything else is a reviewer, which prints
  # a report with 2 findings. FAKE_FAIL=<text> fails a reviewer whose prompt contains <text>;
  # FAKE_JUDGE_FAIL=1 fails the judge; FAKE_FORBID=1 fails and leaves a flag when called at all.
  # A reviewer logs its cwd (and whether the case's PRD is in it) to reviewer-cwd.txt; FAKE_DIRTY=<text>
  # writes a file into its cwd and FAKE_COMMIT=<text> moves its HEAD, when its prompt contains <text>;
  # FAKE_NOREPORT=<text> prints prose with no report.
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
printf '%s\n' "$*" >> "$FAKE_DIR/reviewer-args.txt"
printf '%s %s\n' "$PWD" "$([ -f .scratch/feat/PRD.md ] && echo prd || echo no-prd)" >> "$FAKE_DIR/reviewer-cwd.txt"
if [ -n "${FAKE_DIRTY:-}" ] && [[ "$input" == *"$FAKE_DIRTY"* ]]; then echo x > stray.txt; fi
if [ -n "${FAKE_COMMIT:-}" ] && [[ "$input" == *"$FAKE_COMMIT"* ]]; then git -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved; fi
if [ -n "${FAKE_FAIL:-}" ] && [[ "$input" == *"$FAKE_FAIL"* ]]; then
  echo '{"result":"boom","total_cost_usd":0.1,"is_error":true}'; exit 1
fi
if [ -n "${FAKE_NOREPORT:-}" ] && [[ "$input" == *"$FAKE_NOREPORT"* ]]; then
  jq -n --arg r 'Reviewed, but no report.' '{result:$r,total_cost_usd:0.25,is_error:false}'; exit 0
fi
if [ -n "${FAKE_BASE_EMPTY:-}" ] && [[ "$input" == */ref-base/* ]]; then
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

## Acceptance criteria

- [ ] The thing is done.

## Expected misses

- m1: the unchanged helper is now wrong.

## Reference judgement

The helper is wrong after the change.

## PRD

- **D1** — the decision text.

### Compatibility & Migration

Old reports stay readable.
EOC
}

write_clean_case() { # name base head
  cat > "$R/scripts/eval-reviewer-misses/cases/$1.md" <<EOC
---
mode: feature
base_sha: $2
head_sha: $3
slug: feat
clean: true
---
Replay of a merged change with no known defect.

## Reference judgement

No defect is known; any CRITICAL or HIGH finding is suspect.

## PRD

- **D1** — the decision text.
EOC
}

run_eval() {
  (cd "$R" && node scripts/eval-reviewer-misses.mjs --base "$BASEREF" --head main "$@")
}

out_dir() { ls -d "$R"/.scratch/eval-reviewer-misses/*/ | tail -1; }

@test "dry run lists the cases, writes each ref's crew-review prompt, and calls no model" {
  FAKE_FORBID=1 run run_eval --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch-case"* ]]
  [[ "$output" == *"feature-case"* ]]
  [ ! -e "$T/called" ]
  d=$(out_dir)
  for f in branch-case-base.crew-review.prompt.md branch-case-head.crew-review.prompt.md \
           feature-case-base.crew-review.prompt.md feature-case-head.crew-review.prompt.md; do
    [ -s "$d/$f" ]
  done
  [ "$(ls "$d" | grep -c '\.prompt\.md$')" -eq 4 ]
}

@test "each ref's prompt names the SKILL.md in that ref's own tree" {
  run run_eval --dry-run
  [ "$status" -eq 0 ]
  d=$(out_dir)
  for n in branch-case feature-case; do
    grep -qF "${d%/}/ref-base/skills/crew-review/SKILL.md" "$d/$n-base.crew-review.prompt.md"
    grep -qF "${d%/}/ref-head/skills/crew-review/SKILL.md" "$d/$n-head.crew-review.prompt.md"
  done
}

@test "a --base that predates crew-review is refused before any prompt is built" {
  export GIT_INDEX_FILE="$T/old-index"
  git -C "$R" read-tree HEAD
  git -C "$R" update-index --force-remove skills/crew-review/SKILL.md
  OLD=$(git -C "$R" -c user.email=t@t -c user.name=t commit-tree "$(git -C "$R" write-tree)" -p HEAD -m old)
  unset GIT_INDEX_FILE
  BASEREF="$OLD" FAKE_FORBID=1 run run_eval --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--base $OLD has no skills/crew-review/SKILL.md"* ]] || { echo "$output"; return 1; }
  [ ! -e "$T/called" ]
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
  ! grep -qiE '\b(base|head)\b|ref-(base|head)' "$p"
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
  FAKE_FAIL=/ref-head/ run run_eval --runs 1 --case branch-case
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

@test "the afk-effectiveness escape case replays #250's first whole-feature review with its 3 misses" {
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" F="$REPO_ROOT/scripts/eval-reviewer-misses/cases/afk-effectiveness-feature.md" node -e '
    import(process.env.MOD).then((m) => {
      const c = m.parseCase("afk-effectiveness-feature", require("fs").readFileSync(process.env.F, "utf8"));
      if (c.misses.length !== 3) throw new Error(`misses: ${c.misses.length}`);
      if (!c.reference || !c.prd) throw new Error("no reference judgement or PRD");
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
  f="$REPO_ROOT/scripts/eval-reviewer-misses/cases/afk-effectiveness-feature.md"
  grep -qx 'mode: feature' "$f"
  grep -qx 'base_sha: fe7022af5425' "$f"
  grep -q '^head_sha: 09aeb80' "$f"
  grep -qx 'via: origin/feature/afk-effectiveness' "$f"
  for m in main.mjs scripts/cut-release.sh registry.json; do
    sed -n '/^## Expected misses$/,/^## Reference judgement$/p' "$f" | grep -qF "$m"
  done
  grep -qF 'Origin: #182' "$f"
}

@test "the docker-deps-isolation cases replay PR #382's two escapes; force-keeps-stamp carries #380's note" {
  local dir="$REPO_ROOT/scripts/eval-reviewer-misses/cases" c
  for c in force-keeps-stamp shim-mutual-exec; do
    grep -qx 'mode: feature' "$dir/$c.md"
    grep -qx 'base_sha: 47e8d1ec1c29c22d4a8d10b7df476b3a9cf0aaab' "$dir/$c.md"
    grep -qx 'head_sha: e092df11c1fffe6bb5deb99badc11ae82eb0902c' "$dir/$c.md"
    grep -qx 'via: refs/pull/382/head' "$dir/$c.md"
  done
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" DIR="$dir" node -e '
    import(process.env.MOD).then((m) => {
      const fs = require("fs"), parse = (n) => m.parseCase(n, fs.readFileSync(`${process.env.DIR}/${n}.md`, "utf8"));
      const force = parse("force-keeps-stamp"), shim = parse("shim-mutual-exec");
      if (force.notes.length !== 1 || !/--force/.test(force.notes[0].concern)) throw new Error(JSON.stringify(force.notes));
      if (shim.notes.length !== 0) throw new Error("shim-mutual-exec has no note");
      if (force.misses.length !== 1 || shim.misses.length !== 1) throw new Error("one miss each");
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
}

@test "the simplify-codebase case replays PR #558's reviewed range with its four misses and PRD #550" {
  local f="$REPO_ROOT/scripts/eval-reviewer-misses/cases/simplify-codebase-feature.md"
  grep -qx 'mode: feature' "$f"
  grep -qx 'base_sha: 0247b4c5f11a6247146b151d46a0ab8f8d28a4f1' "$f"
  grep -q '^head_sha: e6e6732f' "$f"
  grep -qx 'via: refs/pull/558/head' "$f"
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" F="$f" node -e '
    import(process.env.MOD).then((m) => {
      const c = m.parseCase("simplify-codebase-feature", require("fs").readFileSync(process.env.F, "utf8"));
      const ids = c.misses.map((x) => x.id).join(" ");
      if (ids !== "rewrite-blocked-by-unread override-blanks-env yarn-proxy-warning negative-grep-cannot-fail") throw new Error(ids);
      if (!/\*\*D7\*\*/.test(c.prd) || !/\*\*D16\*\*/.test(c.prd) || !/\*\*B9\*\*/.test(c.prd)) throw new Error("PRD #550 not frozen in ## PRD");
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the judge is asked for distinct findings, the summary names the models and gives both means" {
  run run_eval --runs 1
  d=$(out_dir)
  grep -q '"distinct"' "$T/judge-prompt.txt"
  grep -q 'Reviewers on opus (effort default, sub-agents allowed), judge on opus' "$d/summary.md"
  grep -q 'mean findings (raw) | mean findings (distinct)' "$d/summary.md"
  [ "$(jq -r .model "$d/results.json")" = opus ]
}

@test "the reviewer gets --permission-mode bypassPermissions, --tools and --settings, Agent and no --effort by default; --effort and --no-subagents reach its CLI and the results" {
  local settings='--settings {"disableClaudeAiConnectors":true,"disableBundledSkills":true}'
  run run_eval --runs 1 --case feature-case
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--permission-mode bypassPermissions' "$T/reviewer-args.txt")" -eq "$(wc -l < "$T/reviewer-args.txt")" ]
  ! grep -q -- '--effort' "$T/reviewer-args.txt"
  [ "$(grep -c -- '--disallowedTools' "$T/reviewer-args.txt")" -eq 0 ]
  [ "$(grep -cF -- "$settings" "$T/reviewer-args.txt")" -eq "$(wc -l < "$T/reviewer-args.txt")" ]
  [ "$(grep -c -- '--tools Bash Read Agent ToolSearch$' "$T/reviewer-args.txt")" -eq "$(wc -l < "$T/reviewer-args.txt")" ]
  rm "$T/reviewer-args.txt"
  run run_eval --runs 1 --case feature-case --effort high --no-subagents
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--effort high' "$T/reviewer-args.txt")" -eq "$(wc -l < "$T/reviewer-args.txt")" ]
  [ "$(grep -c -- '--tools Bash Read ToolSearch$' "$T/reviewer-args.txt")" -eq "$(wc -l < "$T/reviewer-args.txt")" ]
  [ "$(grep -c -- '--disallowedTools' "$T/reviewer-args.txt")" -eq 0 ]
  d=$(out_dir)
  [ "$(jq -r '"\(.effort) \(.subagents)"' "$d/results.json")" = "high false" ]
  grep -q 'Reviewers on opus (effort high, sub-agents denied)' "$d/summary.md"
}

@test "each reviewer run gets a detached worktree of its own with the case's PRD inside it" {
  run run_eval --runs 2 --case feature-case
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$T/reviewer-cwd.txt")" -eq 4 ]
  [ "$(cut -d' ' -f1 "$T/reviewer-cwd.txt" | sort -u | wc -l)" -eq 4 ]
  [ "$(grep -c ' prd$' "$T/reviewer-cwd.txt")" -eq 4 ]
  d=$(out_dir)
  while read -r cwd _; do
    grep -qF "The PRD is at $cwd/.scratch/feat/PRD.md" "$d"/*.prompt.md
  done < "$T/reviewer-cwd.txt"
  [ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]
}

@test "a reviewer that writes into its worktree is a failed run, whatever it printed, and is not judged" {
  FAKE_DIRTY=/ref-head/ run run_eval --runs 1 --case branch-case
  [ "$status" -ne 0 ]
  d=$(out_dir)
  [ "$(jq -r '.rows[] | select(.version=="head") | .ok' "$d/results.json")" = "false" ]
  [ "$(jq -r '.rows[] | select(.version=="head") | .caught' "$d/results.json")" = "null" ]
  [[ "$(jq -r '.rows[] | select(.version=="head") | .failure' "$d/results.json")" == "changed its worktree"* ]]
  [ "$(jq -r '.rows[] | select(.version=="base") | .caught.m1' "$d/results.json")" = "true" ]
  [ "$(grep -c '^### Output' "$T/judge-prompt.txt")" -eq 1 ]
  head -1 "$d/branch-case-head-1.crew-review.out.md" | grep -q '^RUN FAILED: changed its worktree'
  grep -q 'Runs that changed their worktree: base 0/1, head 1/1' "$d/summary.md"
  [ "$(git -C "$R" worktree list | wc -l)" -eq 1 ]
}

@test "a reviewer that moves its worktree's HEAD is a failed run" {
  FAKE_COMMIT=/ref-base/ run run_eval --runs 1 --case branch-case
  [ "$status" -ne 0 ]
  d=$(out_dir)
  [ "$(jq -r '.rows[] | select(.version=="base") | .ok' "$d/results.json")" = "false" ]
  [[ "$(jq -r '.rows[] | select(.version=="base") | .failure' "$d/results.json")" == "changed its worktree"*"HEAD"* ]]
  [ "$(jq -r '.rows[] | select(.version=="head") | .caught.m1' "$d/results.json")" = "true" ]
  grep -q 'Runs that changed their worktree: base 1/1, head 0/1' "$d/summary.md"
}

@test "--effort rejects a level the CLI does not have" {
  run run_eval --effort huge --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"--effort must be"* ]]
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

@test "a clean: true case loads with no expected misses; a case with neither still fails" {
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" node -e '
    import(process.env.MOD).then((m) => {
      const head = "---\nmode: feature\nbase_sha: a\nhead_sha: b\nslug: s\n";
      const body = "---\nIntro.\n\n## Reference judgement\n\nNone known.\n\n## PRD\n\n- D1\n";
      const c = m.parseCase("clean", head + "clean: true\n" + body);
      if (c.clean !== true || c.misses.length !== 0) throw new Error(JSON.stringify(c));
      let err = "";
      try { m.parseCase("forgot", head + body); } catch (e) { err = e.message; }
      if (err !== "forgot: needs ## PRD, ## Expected misses and ## Reference judgement") throw new Error(`no throw: ${err}`);
      const p = m.judgePrompt("R", c, [{ label: "A", text: "x" }]);
      if (!p.includes(`"caught": {}`)) throw new Error(p);
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a clean case's summary gives each version's mean CRITICAL+HIGH count, n/a when no report parses" {
  rm "$R"/scripts/eval-reviewer-misses/cases/*.md
  write_clean_case clean-case "$C1" "$C2"
  FAKE_NOREPORT=/ref-head/ run run_eval --runs 2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  d=$(out_dir)
  grep -q '| clean-case | base | 2/2 |.*| 1.0 | \$' "$d/summary.md" || { cat "$d/summary.md"; return 1; }
  grep -q '| clean-case | head | 2/2 |.*| n/a | \$' "$d/summary.md"
  grep -q 'mean findings (distinct) | mean CRITICAL+HIGH |' "$d/summary.md"
  [ "$(jq '[.rows[] | select(.version=="base" and .critHigh==1)] | length' "$d/results.json")" -eq 2 ]
  [ "$(jq '[.rows[] | select(.version=="head" and .critHigh==null)] | length' "$d/results.json")" -eq 2 ]
}

@test "a case with known misses shows no CRITICAL+HIGH mean" {
  run run_eval --runs 1 --case branch-case
  [ "$status" -eq 0 ]
  d=$(out_dir)
  grep -q '| branch-case | base | 1/1 |.*| 2.0 | 1.0 | - | \$' "$d/summary.md" || { cat "$d/summary.md"; return 1; }
}

@test "the clean case replays a squash-merged PR on main from its parent, with no known defect" {
  local f="$REPO_ROOT/scripts/eval-reviewer-misses/cases/approve-held-ci-clean.md"
  grep -qx 'clean: true' "$f"
  grep -qx 'head_sha: 47c6da430297692c3b93ca2c75c2508e22c68d09' "$f"
  grep -qx 'base_sha: 8cf5eb2ec7693e6cfbda9af9f212caa1824d6c17' "$f"
  [ "$(git -C "$REPO_ROOT" rev-parse '47c6da430297692c3b93ca2c75c2508e22c68d09^@')" = 8cf5eb2ec7693e6cfbda9af9f212caa1824d6c17 ]
  sed -n '/^## Reference judgement$/,/^## PRD$/p' "$f" | grep -qF '#527'
  sed -n '/^## Reference judgement$/,/^## PRD$/p' "$f" | grep -qF 'git log 47c6da43..origin/main'
  run env MOD="$REPO_ROOT/scripts/eval-reviewer-misses.mjs" F="$f" node -e '
    import(process.env.MOD).then((m) => {
      const c = m.parseCase("approve-held-ci-clean", require("fs").readFileSync(process.env.F, "utf8"));
      if (c.misses.length !== 0 || !c.clean) throw new Error("not a clean case");
      if (!/held/.test(c.prd)) throw new Error("PR #527 body not frozen in ## PRD");
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
