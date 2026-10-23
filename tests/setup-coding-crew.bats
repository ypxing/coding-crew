#!/usr/bin/env bats

# The setup-coding-crew skill: what install.sh ships for it, and the pieces of its SKILL.md that are code rather
# than prose: Step 2's start of the dev commands file and Step 4's commit hint; the review-round parts of
# hosts/github-actions.yml (the rest of that file is in solve-feature.bats).

load helpers/yaml

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  TEMP_DIR="$(cd "$(mktemp -d)" && pwd -P)" # resolved, as git prints it: macOS TMPDIR is under a /var symlink
}
teardown() { rm -rf "$TEMP_DIR"; }

@test "install.sh claude --skill setup-coding-crew ships SKILL.md, the Actions template, both discovery scripts and configure-tracker" {
  local target="$TEMP_DIR/target" skill
  mkdir -p "$target" && git -C "$target" init -q -b main
  run env TARGET_REPO="$target" bash "$REPO_ROOT/install.sh" claude --skill setup-coding-crew
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  skill="$target/.claude/skills/setup-coding-crew"
  [ -f "$skill/SKILL.md" ]
  [ -f "$skill/hosts/github-actions.yml" ]
  local lib="$target/.claude/skills/coding-crew-lib/scripts"
  [ -f "$lib/checks/discover-commands.sh" ]
  [ -f "$lib/checks/write-commands-cache.sh" ]
  [ -f "$lib/checks/run-checks.sh" ]
  [ -f "$target/.claude/skills/dep-install/SKILL.md" ]
  [ -f "$lib/tracker/cli.mjs" ]
  [ -f "$target/.claude/skills/configure-tracker/SKILL.md" ]
  [ "$(jq -c '.skills["setup-coding-crew"].deps' "$REPO_ROOT/registry.json")" = '["configure-tracker","dep-install","coding-crew-lib"]' ]
}

# block <n> — the first bash block under SKILL.md's "## Step <n>" heading, <skill-dir> pointing at the source skill.
block() {
  awk -v h="^## Step $1" '$0 ~ h { s = 1; next } /^## / { s = 0 } s && /^```bash/ { c = 1; next } s && c && /^```/ { exit } c' \
    "$REPO_ROOT/skills/setup-coding-crew/SKILL.md" | sed "s#<skill-dir>#$REPO_ROOT/skills/setup-coding-crew#g"
}
# step4 — Step 4's block, START (the tree setup started in) the directory it runs in unless the test sets it.
step4() { block 4 | sed 's#^START="<[^>]*>"#START="${START:-$(git rev-parse --show-toplevel)}"#'; }

# repo_with_worktree — $REPO, a main checkout with one commit, and $WT, a linked worktree of it.
repo_with_worktree() {
  REPO="$TEMP_DIR/repo" WT="$TEMP_DIR/wt"
  git init -q -b main "$REPO"
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$REPO" worktree add -q --detach "$WT"
}

@test "Step 2 moves the clone's old .git/coding-crew/ file to the main checkout's file, from a linked worktree too" {
  repo_with_worktree
  block 2 > "$TEMP_DIR/step2.sh"
  grep -q 'commands-file.sh' "$TEMP_DIR/step2.sh"
  mkdir -p "$REPO/.git/coding-crew"
  echo '{"test": "make test", "install_mode": "host"}' > "$REPO/.git/coding-crew/dev-commands.json"
  (cd "$WT" && bash "$TEMP_DIR/step2.sh") >/dev/null
  [ ! -e "$REPO/.git/coding-crew/dev-commands.json" ]
  grep -q '"test": "make test"' "$REPO/.coding-crew/dev-commands.json"
  [ ! -e "$WT/.coding-crew" ]

  # An existing project file is kept; with no old file either, it starts empty.
  echo '{"test": "make check"}' > "$REPO/.coding-crew/dev-commands.json"
  echo '{"test": "old"}' > "$REPO/.git/coding-crew/dev-commands.json"
  (cd "$REPO" && bash "$TEMP_DIR/step2.sh") >/dev/null
  grep -q '"test": "make check"' "$REPO/.coding-crew/dev-commands.json"
  rm -rf "$REPO/.coding-crew" "$REPO/.git/coding-crew"
  (cd "$REPO" && bash "$TEMP_DIR/step2.sh") >/dev/null
  [ -f "$REPO/.coding-crew/dev-commands.json" ]
}

@test "setup verifies the commands: dep-install by name, then run-checks.sh, offering fix, keep or stop on a failure" {
  local skill="$REPO_ROOT/skills/setup-coding-crew/SKILL.md"
  grep -qF 'Use the dep-install skill' "$skill"
  grep -qF 'scripts/checks/run-checks.sh' "$skill"
  grep -qF 'CHECKS: fail' "$skill"
  grep -qF '**fix**' "$skill" && grep -qF '**keep**' "$skill" && grep -qF '**stop**' "$skill"
  ! grep -n 'dep-install/' "$skill" || false
  ! grep -nE 'Never run the commands|This step does not decide it|solve-feature needs these files committed|the tracked `.coding-crew' "$skill" || false
}

@test "the commit hint for a setup started in a linked worktree lists the main checkout's files, with a cd there" {
  repo_with_worktree
  step4 > "$TEMP_DIR/hint.sh"
  mkdir -p "$REPO/.coding-crew"
  echo '{"test": "make test"}' > "$REPO/.coding-crew/dev-commands.json"
  # Setup runs every command from the main checkout; only START remembers the worktree it was started in.
  run bash -c 'cd "$1" && START="$2" bash "$3"' _ "$REPO" "$WT" "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd $REPO && git add .coding-crew/dev-commands.json && git commit"* ]] || { echo "$output"; return 1; }
}

@test "the commit hint labels each kept failing check unverified, above the commit line" {
  local repo="$TEMP_DIR/repo"
  step4 | sed 's/^UNVERIFIED=""/UNVERIFIED="lint test"/' > "$TEMP_DIR/hint.sh"
  grep -q '^UNVERIFIED="lint test"' "$TEMP_DIR/hint.sh"
  mkdir -p "$repo" && cd "$repo" && git init -q -b main
  mkdir -p .coding-crew && echo '{"test": "make test"}' > .coding-crew/dev-commands.json
  run bash "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "unverified: lint fails" ]
  [ "${lines[1]}" = "unverified: test fails" ]
  [[ "${lines[2]}" == "To finish, run: git add .coding-crew/dev-commands.json && git commit"* ]]
}

@test "the commit hint lists each setup file git shows as changed or untracked, and says when all are committed" {
  local repo="$TEMP_DIR/repo"
  step4 > "$TEMP_DIR/hint.sh"
  [ -s "$TEMP_DIR/hint.sh" ]
  mkdir -p "$repo" && cd "$repo" && git init -q -b main
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  mkdir -p .coding-crew .github/workflows
  echo '{"tracker": {"kind": "github"}}' > .coding-crew/config.json
  echo '{"test": "make test"}' > .coding-crew/dev-commands.json
  echo 'name: other' > .github/workflows/other.yml
  git add .coding-crew/dev-commands.json && git -c user.name=t -c user.email=t@t commit -q -m cmds
  echo '{"test": "make check"}' > .coding-crew/dev-commands.json

  run bash "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'git add .coding-crew/config.json .coding-crew/dev-commands.json && git commit -m "Set up coding-crew"'* ]]
  [[ "$output" != *other.yml* ]]

  git add .coding-crew && git -c user.name=t -c user.email=t@t commit -q -m setup
  run bash "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"git add"* ]]
  [[ "$output" == *"committed"* ]]
}

@test "the skill runs no git commit or git push itself, says so, and reaches configure-tracker only by name" {
  local skill="$REPO_ROOT/skills/setup-coding-crew/SKILL.md"
  # A command block may print a git commit line, never run one.
  ! awk '/^ *```bash/ { c = 1; next } /^ *```/ { c = 0 } c' "$skill" | grep -E 'git (commit|push)' | grep -v 'echo ' || false
  grep -qF 'does not commit or push' "$skill"
  grep -qF 'Use the configure-tracker skill' "$skill"
  ! grep -n 'configure-tracker/' "$skill" || false
}

# actions_tracker — Step 3's bash block that writes the tracker into the project's config.json.
actions_tracker() {
  awk '/^```bash/ { c = 1; b = ""; next } c && /^```/ { c = 0; if (b ~ /Wrote tracker github/) { printf "%s", b; exit } next } c { b = b $0 "\n" }' \
    "$REPO_ROOT/skills/setup-coding-crew/SKILL.md"
}

@test "on yes to Actions, Step 3 writes tracker github into a config.json with no tracker section, keeping the rest, then the hint lists it" {
  local repo="$TEMP_DIR/repo"
  actions_tracker > "$TEMP_DIR/actions.sh"
  [ -s "$TEMP_DIR/actions.sh" ]
  awk '/^## Step 3/ { s = 1 } /^## Step 4/ { s = 0 } s' "$REPO_ROOT/skills/setup-coding-crew/SKILL.md" | grep -q 'Wrote tracker github'
  step4 > "$TEMP_DIR/hint.sh"
  mkdir -p "$repo" && cd "$repo" && git init -q -b main
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

  run bash "$TEMP_DIR/actions.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "Wrote tracker github to .coding-crew/config.json: the Actions runner sees only the project's files" ]
  [ "$(jq -c . .coding-crew/config.json)" = '{"tracker":{"kind":"github"}}' ]
  run bash "$TEMP_DIR/hint.sh"
  [[ "$output" == *'git add .coding-crew/config.json && git commit'* ]]

  echo '{"solveFeature":{"models":{"coder":"sonnet"}}}' > .coding-crew/config.json
  git add .coding-crew && git -c user.name=t -c user.email=t@t commit -q -m cfg
  run bash "$TEMP_DIR/actions.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -c . .coding-crew/config.json)" = '{"solveFeature":{"models":{"coder":"sonnet"}},"tracker":{"kind":"github"}}' ]
  run bash "$TEMP_DIR/hint.sh"
  [[ "$output" == *'git add .coding-crew/config.json && git commit'* ]]

  echo '{"tracker":{"kind":"local"}}' > .coding-crew/config.json
  git add .coding-crew && git -c user.name=t -c user.email=t@t commit -q -m local
  run bash "$TEMP_DIR/actions.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(git status --porcelain)" ]
}

# --- hosts/github-actions.yml: review rounds ---------------------------------------------

# host_json — the host file as $JSON, or skips the test when the machine has no YAML parser; $STUB first on PATH and
# the test in $TEMP_DIR/work, where a step's run script is run as Actions would.
host_json() {
  JSON="$TEMP_DIR/wf.json"
  run yaml_to_json "$REPO_ROOT/skills/setup-coding-crew/hosts/github-actions.yml" "$JSON"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  STUB="$TEMP_DIR/stub" && mkdir -p "$STUB" "$TEMP_DIR/work" && cd "$TEMP_DIR/work"
  export PATH="$STUB:$PATH"
}
# step_run <job> <step name> — that step's run script, into $TEMP_DIR/<job>-step.sh.
step_run() {
  jq -r --arg n "$2" ".jobs.$1.steps[] | select(.name == \$n) | .run" "$JSON" > "$TEMP_DIR/$1-step.sh"
  [ -s "$TEMP_DIR/$1-step.sh" ]
}

@test "host file: a submitted review other than an approval starts a round (a review comment or a resolved thread alone does not), the solve job runs only on a slug, and no run line interpolates an expression" {
  host_json
  local on='(.on // .["true"])'
  [ "$(jq -c "$on.pull_request_review.types" "$JSON")" = '["submitted"]' ]
  [ "$(jq -r "$on | has(\"pull_request_review_thread\")" "$JSON")" = false ]
  [ "$(jq -r "$on | has(\"pull_request_review_comment\")" "$JSON")" = false ]
  [ "$(jq -c "$on.issues.types" "$JSON")" = '["labeled"]' ]
  jq -e '.jobs.slug.if | test("workflow_dispatch") and test("run-agent") and test("pull_request_review") and test("github.event.review.state != .approved.")' "$JSON" >/dev/null
  jq -e '.jobs.slug.steps[0].env.REVIEW_AUTHOR == "${{ github.event.review.user.login }}"' "$JSON" >/dev/null
  jq -e '.jobs.solve.if | test("needs.slug.outputs.slug != ..")' "$JSON" >/dev/null
  # The PR body and every other event field reach a shell only through env: interpolated into a run line it runs as code.
  [ "$(jq '[.jobs[].steps[] | .run // empty | select(test("[$][{][{]"))] | length' "$JSON")" -eq 0 ]
  jq -e '.jobs.slug.steps[0].env.PR_BODY == "${{ github.event.pull_request.body }}"' "$JSON" >/dev/null
}

@test "host file: a review round's slug comes from the PR body's block, only for Copilot's reviewer or a user with write, maintain or admin; a label run's from the root issue, the same slug" {
  host_json
  step_run slug "Read the slug"
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$TEMP_DIR/gh.log"
[ -z "$GH_FAIL" ] || { echo "HTTP 404" >&2; exit 1; }
printf '%s\n' $GH_PERM
SH
  chmod +x "$STUB/gh"
  export TEMP_DIR RUNNER_TEMP="$TEMP_DIR" GITHUB_OUTPUT="$TEMP_DIR/out" GITHUB_REPOSITORY=o/r INPUT_SLUG= ISSUE_BODY= PR_NUMBER=12
  local body=$'Why.\n\n<!-- solve-feature:begin -->\nImplemented by solve-feature (`feat`).\n<!-- solve-feature:slug feat -->\n<!-- solve-feature:end -->'
  # round <author> [gh perm lines] — runs the step for a review event; $output and $GITHUB_OUTPUT hold the result.
  round() { : > "$GITHUB_OUTPUT"; rm -f "$TEMP_DIR/gh.log"; GITHUB_EVENT_NAME=pull_request_review PR_BODY="$PR_BODY" REVIEW_AUTHOR="$1" GH_PERM="$2" run bash -e "$TEMP_DIR/slug-step.sh"; }

  export PR_BODY="$body"
  round 'copilot-pull-request-reviewer[bot]'
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = $'slug=feat\npr=12' ]
  [ ! -e "$TEMP_DIR/gh.log" ]
  local perm
  for perm in $'write\nwrite' $'admin\nadmin' $'write\nmaintain'; do
    round alice "$perm"
    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_OUTPUT")" = $'slug=feat\npr=12' ] || { echo "$perm: $(cat "$GITHUB_OUTPUT")"; return 1; }
    [ "$(cat "$TEMP_DIR/gh.log")" = 'gh api repos/o/r/collaborators/alice/permission --jq .permission, .role_name' ]
  done
  # Anyone else, the agent's own token included, starts nothing: a notice and no slug, so solve is skipped.
  for perm in $'read\ntriage' $'none\nnone' $'read\nread'; do
    round mallory "$perm"
    [ "$status" -eq 0 ]
    [ ! -s "$GITHUB_OUTPUT" ]
    [[ "$output" == *"::notice::"*"mallory"* ]]
  done
  GH_FAIL=1 round mallory
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
  [[ "$output" == *"::notice::"* ]]
  round 'github-actions[bot]' $'read\nread'
  [ ! -s "$GITHUB_OUTPUT" ]
  # A PR without the block is not solve-feature's, whoever reviewed it.
  PR_BODY=$'Why.\n<!-- solve-feature:slug feat -->' round 'copilot-pull-request-reviewer[bot]'
  [ "$status" -eq 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
  [[ "$output" == *"::notice::"*"solve-feature"* ]]
  # A body that is code in a shell line stays text.
  PR_BODY=$'<!-- solve-feature:begin -->\n$(touch pwned)\n<!-- solve-feature:slug feat -->' round 'copilot-pull-request-reviewer[bot]'
  [ "$(cat "$GITHUB_OUTPUT")" = $'slug=feat\npr=12' ]
  [ ! -e pwned ]

  # A label run of the same feature gets the same slug, so both queue in solve-feature-feat; no pr output.
  : > "$GITHUB_OUTPUT"
  GITHUB_EVENT_NAME=issues ISSUE_BODY=$'Feature: feat\n\nRoot.' PR_BODY= run bash -e "$TEMP_DIR/slug-step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'slug=feat' ]
  : > "$GITHUB_OUTPUT"
  GITHUB_EVENT_NAME=issues ISSUE_BODY='no line' PR_BODY= run bash -e "$TEMP_DIR/slug-step.sh"
  [ "$status" -ne 0 ]
  GITHUB_EVENT_NAME=workflow_dispatch INPUT_SLUG=feat PR_BODY= run bash -e "$TEMP_DIR/slug-step.sh"
  [ "$(cat "$GITHUB_OUTPUT")" = 'slug=feat' ]
  [ "$(jq -r '.jobs.solve.concurrency.group' "$JSON")" = 'solve-feature-${{ needs.slug.outputs.slug }}' ]
}

@test "host file: a review round's session runs address-pr-comments on the PR, saying it is non-interactive, for both agents; the install includes the skill" {
  host_json
  step_run solve "Run solve-feature"
  for a in copilot claude; do
    printf '#!/usr/bin/env bash\necho "%s $*"\n' "$a" > "$STUB/$a" && chmod +x "$STUB/$a"
  done
  local sentence='Use the address-pr-comments skill on PR #12; this run is non-interactive'
  run env CREW_AGENT=copilot CREW_MODEL= SLUG=feat REVIEW_PR=12 ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/solve-step.sh"
  [ "$status" -eq 0 ]
  [[ "$(head -n 1 .coding-crew/solve-feature/session.jsonl)" == "copilot -p $sentence --allow-all "* ]]
  run env CREW_AGENT=claude CREW_MODEL= SLUG=feat REVIEW_PR=12 ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=tok bash -e "$TEMP_DIR/solve-step.sh"
  [ "$status" -eq 0 ]
  [[ "$(head -n 1 .coding-crew/solve-feature/session.jsonl)" == "claude -p /address-pr-comments 12 $sentence --dangerously-skip-permissions "* ]]
  # A label or dispatch run keeps its prompt.
  run env CREW_AGENT=copilot CREW_MODEL= SLUG=feat REVIEW_PR= ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/solve-step.sh"
  [[ "$(head -n 1 .coding-crew/solve-feature/session.jsonl)" == "copilot -p Use the solve-feature skill on feat --allow-all "* ]]
  jq -e '.jobs.solve.steps[] | select(.name == "Run solve-feature") | .env.REVIEW_PR == "${{ needs.slug.outputs.pr }}"' "$JSON" >/dev/null
  step_run solve "Install coding-crew (user-level)"
  grep -qE -- '--skills [a-z,-]*address-pr-comments' "$TEMP_DIR/solve-step.sh"
}

@test "host file: after a ready run, Copilot is asked to review with the PAT only when it has not reviewed; unset or refused, the step warns and passes" {
  host_json
  local name="Ask Copilot for its review"
  step_run solve "$name"
  # The PAT is that step's GH_TOKEN, and no other step's; it always runs after the session, before the bundle.
  [ "$(jq -c '[.jobs[].steps[] | select((.env // {}) | tostring | test("COPILOT_GITHUB_TOKEN")) | .name]' "$JSON")" = "[\"$name\"]" ]
  jq -e --arg n "$name" '.jobs.solve.steps[] | select(.name == $n) | .env.GH_TOKEN == "${{ secrets.COPILOT_GITHUB_TOKEN }}" and .if == "always()"' "$JSON" >/dev/null
  [ "$(jq -r '.jobs.solve.steps | map(.name) | (index("Run solve-feature") < index("Ask Copilot for its review")) and (index("Ask Copilot for its review") < index("Bundle the unpushed commits"))' "$JSON")" = true ]
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
echo "GH_TOKEN=$GH_TOKEN gh $*" >> "$TEMP_DIR/gh.log"
case "$1 $2" in
  "api repos/o/r/pulls/12/reviews") [ -z "$GH_LIST_FAIL" ] || exit 1; printf '%s\n' $GH_REVIEWERS ;;
  "pr edit") [ -z "$GH_EDIT_FAIL" ] || { echo "HTTP 422" >&2; exit 1; } ;;
esac
SH
  chmod +x "$STUB/gh"
  export TEMP_DIR GITHUB_REPOSITORY=o/r READ_TOKEN=gha GH_REVIEWERS=alice
  mkdir -p .coding-crew/solve-feature && echo 'ready pr=12' > .coding-crew/solve-feature/outcome

  GH_TOKEN=pat run bash -e "$TEMP_DIR/solve-step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEMP_DIR/gh.log")" = "$(printf '%s\n' 'GH_TOKEN=gha gh api repos/o/r/pulls/12/reviews --paginate --jq .[].user.login' \
    'GH_TOKEN=pat gh pr edit 12 --add-reviewer @copilot')" ]
  # Copilot reviewed already: a second request would re-review, every ready round.
  rm -f "$TEMP_DIR/gh.log"
  GH_TOKEN=pat GH_REVIEWERS='alice copilot-pull-request-reviewer[bot]' run bash -e "$TEMP_DIR/solve-step.sh"
  [ "$status" -eq 0 ]
  ! grep -q 'pr edit' "$TEMP_DIR/gh.log" || false
  rm -f "$TEMP_DIR/gh.log"
  GH_TOKEN= run bash -e "$TEMP_DIR/solve-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"*"COPILOT_GITHUB_TOKEN"*"by hand"* ]]
  ! grep -q 'pr edit' "$TEMP_DIR/gh.log" || false
  GH_TOKEN=pat GH_EDIT_FAIL=1 run bash -e "$TEMP_DIR/solve-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  rm -f "$TEMP_DIR/gh.log"
  GH_TOKEN=pat GH_LIST_FAIL=1 run bash -e "$TEMP_DIR/solve-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  ! grep -q 'pr edit' "$TEMP_DIR/gh.log" || false
  for line in 'needs-attention pr=12' 'stopped: 2 checks failed: x' ''; do
    rm -f "$TEMP_DIR/gh.log" .coding-crew/solve-feature/outcome
    [ -z "$line" ] || echo "$line" > .coding-crew/solve-feature/outcome
    GH_TOKEN=pat run bash -e "$TEMP_DIR/solve-step.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$TEMP_DIR/gh.log" ]
  done
}

@test "host file: a review round with no outcome or needs-attention ends with a notice, a stopped one fails; a label run keeps its rule" {
  host_json
  jq -r '.jobs.solve.steps[-1].run' "$JSON" > "$TEMP_DIR/last-step.sh"
  jq -e '.jobs.solve.steps[-1].env.REVIEW_PR == "${{ needs.slug.outputs.pr }}"' "$JSON" >/dev/null
  export GITHUB_STEP_SUMMARY="$TEMP_DIR/summary.md" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r \
    CREW_AGENT=claude CREW_MODEL= SLUG=feat
  REVIEW_PR=12 run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"*"no solve-feature run this round"* ]]
  grep -qxF -- '- PR: https://github.com/o/r/pull/12' "$GITHUB_STEP_SUMMARY"
  REVIEW_PR= run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never finished"* ]]
  mkdir -p .coding-crew/solve-feature
  echo 'needs-attention pr=12' > .coding-crew/solve-feature/outcome
  REVIEW_PR=12 run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"*"needs-attention pr=12"* ]]
  REVIEW_PR= run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  echo 'stopped: 2 checks failed: x' > .coding-crew/solve-feature/outcome
  REVIEW_PR=12 run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"stopped: 2 checks failed: x"* ]]
  echo 'ready pr=12' > .coding-crew/solve-feature/outcome
  REVIEW_PR=12 run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -eq 0 ]
}
