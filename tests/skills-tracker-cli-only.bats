#!/usr/bin/env bats

# Skills reach the tracker only through the tracker CLI (`tracker/cli.mjs`, PRD #328 D1, D9–D12,
# B6): no rendered tracker-touching skill runs `gh` itself or branches on the tracker, the shared
# tracker-configuration fragment is the one place that says how to call the CLI, and the tracker
# templates list CLI commands for a person instead of prose operations. Asserted against the
# rendered output, for every platform — what a consuming repo receives.

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
TRACKER_SKILLS=(to-issues to-prd crew-address-findings upgrade-deps solve-issue crew-grill crew-brainstorm)

# The `## Tracker Configuration` section of a rendered body.
tracker_section() {
  awk '/^## Tracker Configuration$/{f=1;print;next} f&&/^## /{exit} f' "$1"
}

@test "no rendered tracker-touching skill runs gh or branches on the tracker, for every platform" {
  local skill p f
  for skill in "${TRACKER_SKILLS[@]}"; do
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      if grep -nF '`gh ' "$f"; then echo "$skill/$p runs gh" >&2; return 1; fi
      if grep -niE 'under (a |the )?(configured )?`(github|local)`' "$f"; then
        echo "$skill/$p branches on the tracker" >&2; return 1
      fi
      if grep -nF '{{FRAGMENT' "$f"; then echo "$skill/$p left a fragment unexpanded" >&2; return 1; fi
    done
  done
}

@test "the tracker-configuration fragment checks node first, names the CLI with its \$HOME fallback, and forbids working around a failure, for every platform" {
  local skill p f section node_line op_line
  for skill in "${TRACKER_SKILLS[@]}"; do
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      section=$(tracker_section "$f")
      [ -n "$section" ] || { echo "$skill/$p has no Tracker Configuration section" >&2; return 1; }
      grep -qF 'node --version' <<<"$section"
      grep -qF 'the tracker CLI needs Node' <<<"$section"
      grep -qF '"$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs"' <<<"$section"
      grep -qF '"$HOME/.coding-crew/tracker/cli.mjs"' <<<"$section"
      grep -qiF 'fix its cause' <<<"$section"
      grep -qF "never perform the operation with the tracker's own tool" <<<"$section"
      node_line=$(grep -nF 'node --version' <<<"$section" | head -1 | cut -d: -f1)
      op_line=$(grep -nF 'node "$TRACKER"' <<<"$section" | head -1 | cut -d: -f1)
      [ -n "$op_line" ] && [ "$node_line" -lt "$op_line" ]
    done
  done
}

@test "the tracker-configuration fragment makes every op self-contained: the lookup prints an absolute path that replaces \$TRACKER, for every platform" {
  local skill p f section
  for skill in "${TRACKER_SKILLS[@]}"; do
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      section=$(tracker_section "$f")
      # The lookup prints the path it resolved, so a later shell can use it.
      grep -qF 'echo "$TRACKER"' <<<"$section" || { echo "$skill/$p: lookup prints no path" >&2; return 1; }
      # Every `node "$TRACKER" <op>` runs with that absolute path in place of $TRACKER, since a
      # variable set in one shell is gone in the next.
      grep -qF 'fresh shell' <<<"$section" || { echo "$skill/$p: no fresh-shell warning" >&2; return 1; }
      grep -qF 'write the absolute path it printed in place of `$TRACKER`' <<<"$section" ||
        { echo "$skill/$p: no substitution instruction" >&2; return 1; }
    done
  done
  # The instruction's lookup, run in its own shell, resolves to a CLI that exists.
  local repo out
  repo=$(mktemp -d "$BATS_TEST_TMPDIR/repo.XXXXXX")
  git -C "$repo" init -q
  mkdir -p "$repo/.coding-crew/tracker"
  cp "$REPO_ROOT/tracker/"*.mjs "$repo/.coding-crew/tracker/"
  f=$(rendered_skill solve-issue claude)
  out=$(cd "$repo" && bash -c "$(tracker_section "$f" | awk '/^```bash$/{n++;f=(n==2);next} /^```$/{f=0} f' | grep -v '^node "\$TRACKER"')")
  [ "$out" = "$(cd "$repo" && pwd -P)/.coding-crew/tracker/cli.mjs" ] || [ "$out" = "$repo/.coding-crew/tracker/cli.mjs" ]
  [ -f "$out" ]
}

@test "every rendered skill that runs a tracker op defines \$TRACKER through the tracker-configuration lookup, for every platform" {
  local dir skill p f
  for dir in "$REPO_ROOT"/skills/*/; do
    skill=$(basename "$dir")
    [ "$skill" = _shared ] && continue
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      grep -qF 'node "$TRACKER"' "$f" || continue
      grep -qF 'TRACKER="$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs"' "$f" ||
        { echo "$skill/$p runs node \"\$TRACKER\" but never sets it (add {{FRAGMENT:tracker-configuration}})" >&2; return 1; }
    done
  done
}

@test "solve-issue includes the fragment and fetches and marks done through the CLI" {
  grep -qF '{{FRAGMENT:tracker-configuration}}' "$REPO_ROOT/skills/solve-issue/SKILL.md"
  local p f
  for p in "${PLATFORMS[@]}"; do
    f=$(rendered_skill solve-issue "$p")
    grep -qF 'node "$TRACKER" fetch <issue-ref>' "$f"
    grep -qF 'node "$TRACKER" mark-done <issue-ref>' "$f"
    ! grep -qF 'operation from `issue-tracker.md`' "$f"
  done
}

@test "to-issues drafts, lints against known, publishes through publish-issues and rewrites through rewrite, for every platform" {
  local p f
  for p in "${PLATFORMS[@]}"; do
    f=$(rendered_skill to-issues "$p")
    grep -qF 'node "$TRACKER" fetch <ref> --comments' "$f"
    grep -qF 'node "$TRACKER" prd --feature-slug <feature-slug>' "$f"
    grep -qF 'node "$TRACKER" known --feature-slug <feature-slug> --out .scratch/<feature-slug>/.drafts/known' "$f"
    grep -qF -- '--deps .scratch/<feature-slug>/.drafts/deps.json' "$f"
    grep -qF -- '--known <file>' "$f"
    grep -qF 'node "$TRACKER" publish-issues --feature-slug <feature-slug> --drafts .scratch/<feature-slug>/.drafts' "$f"
    grep -qE '^- \*\*Exit 4\*\*.*stop.*Some issues are already completed' "$f"
    grep -qE '^- \*\*Exit 5\*\*.*overwritten.*confirmation.*--replace' "$f"
    grep -qF 'node "$TRACKER" rewrite <ref> --body-file <file> --status <status> --feature-slug <feature-slug>' "$f"
    # One draft set for every tracker: deps.json is written whatever the tracker is.
    ! grep -qiF 'local tracker only' "$f"
    ! grep -qF 'issues-deps.json' "$f"
  done
}

@test "to-prd publishes through publish-prd, crew-address-findings reads the PRD through prd, upgrade-deps names to-issues' write step, for every platform" {
  local p
  for p in "${PLATFORMS[@]}"; do
    grep -qF 'node "$TRACKER" publish-prd --feature-slug <feature-slug> --title "<feature title>" --body-file <file>' "$(rendered_skill to-prd "$p")"
    grep -qF 'node "$TRACKER" prd --feature-slug <feature-slug>' "$(rendered_skill crew-address-findings "$p")"
    grep -qF "the ref \`promote-findings.sh\` prints" "$(rendered_skill crew-address-findings "$p")"
    grep -qF "\`to-issues\`' step 6 (\"Write the issues\")" "$(rendered_skill upgrade-deps "$p")"
    ! grep -qiE 'github|issues-deps\.json' <(awk '/^### 8\. Publish/{f=1;next} /^### /{f=0} f' "$(rendered_skill upgrade-deps "$p")")
  done
}

@test "to-issues' rerun and github-publish references are gone and no rendered skill names them" {
  [ ! -e "$REPO_ROOT/skills/to-issues/references/rerun.md" ]
  [ ! -e "$REPO_ROOT/skills/to-issues/references/github-publish.md" ]
  local skill p
  for skill in "${TRACKER_SKILLS[@]}" crew-afk; do
    for p in "${PLATFORMS[@]}"; do
      ! grep -qE 'rerun\.md|github-publish\.md' "$(rendered_skill "$skill" "$p")"
    done
  done
}

@test "crew-afk's target lookup comment runs no gh" {
  ! grep -qE '#.*gh issue list' "$REPO_ROOT/skills/crew-afk/SKILL.md"
}

@test "the tracker templates have no Operation sections, list the CLI commands, and fix the label strings" {
  local t
  for t in local github; do
    t="$REPO_ROOT/tracker/docs/$t.md"
    ! grep -q '^## Operation:' "$t"
    grep -q '^## Tracker CLI' "$t"
    for op in fetch prd known publish-issues publish-prd rewrite mark-done; do
      grep -qE "^node \"\\\$TRACKER\" $op( |$)" "$t" || { echo "$t lacks the $op command" >&2; return 1; }
    done
  done
  ! grep -qF 'Edit the right-hand column' "$REPO_ROOT/tracker/docs/local.md"
}

@test "the tracker-configuration lookup, run in a linked worktree without .coding-crew/, finds the main checkout's CLI" {
  local repo wt out f
  repo=$(mktemp -d "$BATS_TEST_TMPDIR/repo.XXXXXX")
  git -C "$repo" init -q
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$repo/.coding-crew/tracker"
  cp "$REPO_ROOT/tracker/"*.mjs "$repo/.coding-crew/tracker/"
  wt="$BATS_TEST_TMPDIR/wt"
  git -C "$repo" worktree add -q "$wt"
  [ ! -e "$wt/.coding-crew" ]
  f=$(rendered_skill solve-issue claude)
  out=$(cd "$wt" && HOME="$BATS_TEST_TMPDIR/nohome" bash -c "$(tracker_section "$f" | awk '/^```bash$/{n++;f=(n==2);next} /^```$/{f=0} f' | grep -v '^node "\$TRACKER"')")
  [ "$out" = "$(cd "$repo" && pwd -P)/.coding-crew/tracker/cli.mjs" ]
}

# prompt_layout_leaks <file> — prints each line of a prompt that names the local tracker's layout
# (`issues/open`, `issues/done`) or lists features with `ls`/`find` over `.scratch/` (a `find` that
# selects files by `-path`/`-name`, such as one for review reports, lists no features). Features are
# listed with `node "$TRACKER" features`, which answers for every tracker. Scripts are the local
# backend's mechanism, not prompts, and are not scanned.
prompt_layout_leaks() {
  grep -nE 'issues/(open|done)|\b(ls|find)\b[^|;&]*\.scratch([/ ]|$)' "$1" | grep -vE '^[0-9]+:.*\bfind\b.*-(path|name) ' || true
}

@test "no rendered skill body, role or fragment names the local issue layout or lists features with ls or find over .scratch, for every platform" {
  local dir skill p f hits
  for dir in "$REPO_ROOT"/skills/*/; do
    skill=$(basename "$dir")
    [ "$skill" = _shared ] && continue
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      hits=$(prompt_layout_leaks "$f")
      [ -z "$hits" ] || { echo "$skill/$p names the local layout:" >&2; echo "$hits" >&2; return 1; }
    done
  done
  while IFS= read -r f; do
    hits=$(prompt_layout_leaks "$f")
    [ -z "$hits" ] || { echo "$f names the local layout:" >&2; echo "$hits" >&2; return 1; }
  done < <(find "$REPO_ROOT/orchestrator/roles" "$REPO_ROOT/skills/_shared/fragments" -type f -name '*.md' | sort)
}

@test "the layout check fails, for every platform, on a skill body that names issues/open or lists .scratch with ls or find" {
  local p f
  for p in "${PLATFORMS[@]}"; do
    f=$(rendered_skill crew-afk "$p")
    printf 'x\nls -d .scratch/*/\n' | cat "$f" - > "$BATS_TEST_TMPDIR/ls.md"
    [ -n "$(prompt_layout_leaks "$BATS_TEST_TMPDIR/ls.md")" ]
    printf 'x\nfind .scratch -maxdepth 1\n' | cat "$f" - > "$BATS_TEST_TMPDIR/find.md"
    [ -n "$(prompt_layout_leaks "$BATS_TEST_TMPDIR/find.md")" ]
    printf 'x\ngrep -rl ready .scratch/*/issues/open/*.md\n' | cat "$f" - > "$BATS_TEST_TMPDIR/open.md"
    [ -n "$(prompt_layout_leaks "$BATS_TEST_TMPDIR/open.md")" ]
    printf 'x\nmove it to issues/done/\n' | cat "$f" - > "$BATS_TEST_TMPDIR/done.md"
    [ -n "$(prompt_layout_leaks "$BATS_TEST_TMPDIR/done.md")" ]
  done
}

@test "crew-afk, to-issues and to-prd resolve a feature slug from the features op, for every platform" {
  local skill p f
  for skill in crew-afk to-issues to-prd; do
    for p in "${PLATFORMS[@]}"; do
      f=$(rendered_skill "$skill" "$p")
      grep -qF 'node "$TRACKER" features' "$f" || { echo "$skill/$p does not run features" >&2; return 1; }
    done
  done
}

@test "to-prd asks the user before reusing a slug that features lists, for every platform" {
  local p
  for p in "${PLATFORMS[@]}"; do
    grep -qF 'Before reusing a slug `features` lists, ask the user' "$(rendered_skill to-prd "$p")"
  done
}

@test "add-tests writes no PRD.md and hands its findings file to to-issues; solve-issue names no .scratch PRD.md fallback, for every platform" {
  local p f
  for p in "${PLATFORMS[@]}"; do
    f=$(rendered_skill add-tests "$p")
    ! grep -qF 'PRD.md' <(sed 's/write no `PRD.md`//' "$f")
    grep -qF '.scratch/<feature-slug>/findings.md' "$f"
    grep -qF 'with that findings file as its source' "$f"
    ! grep -qF '.scratch/<feature-slug>/PRD.md' "$(rendered_skill solve-issue "$p")"
  done
}

@test "the ready-for-human Mark it done Undo names no tracker and points at the tracker doc beside the mark-done command's CLI, for every platform" {
  local p f
  for p in "${PLATFORMS[@]}"; do
    f=$(rendered_skill to-issues "$p")
    grep -qF 'Undo:` follow "Reopen an issue" in the tracker doc `.coding-crew/tracker/docs/<kind>.md` — `~/.coding-crew/tracker/docs/<kind>.md` when the `mark-done` command above is the `~/.coding-crew` one' "$f"
    ! grep -qF 'remove `awaiting-merge`' "$f"
  done
}

@test "both tracker docs list the features op and have a Reopen an issue section" {
  local t
  for t in local github; do
    t="$REPO_ROOT/tracker/docs/$t.md"
    grep -qE '^node "\$TRACKER" features( |$)' "$t"
    grep -q '^## Reopen an issue' "$t"
  done
}

@test ".coding-crew/config.json and dev-commands.json are tracked, not ignored, and the guide says to commit them" {
  ! grep -qE '^/?\.coding-crew' "$REPO_ROOT/.gitignore"
  git -C "$REPO_ROOT" ls-files --error-unmatch .coding-crew/config.json .coding-crew/dev-commands.json >/dev/null
  grep -qE 'Commit `.coding-crew/config.json` and `.coding-crew/dev-commands.json`' "$REPO_ROOT/docs/guide.md"
}
