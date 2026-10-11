#!/usr/bin/env bats

# install.sh and uninstall.sh behaviour. Tests that only read what an install leaves behind read
# the installs setup_file makes; the rest install into their own TEMP_DIR.

load helpers/platforms
load helpers/shared-install

setup_file() {
  shared_install all
  shared_install to-issues claude --skill to-issues
  bg_wait
}

setup() {
  ALL="$(shared_installed all)"
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "install skill creates SKILL.md at expected path" {
  [ -f "$ALL/.claude/skills/tdd/SKILL.md" ]
}

@test "manifest contains correct skill name and version after install" {
  [ -f "$ALL/.coding-crew/manifest.json" ]
  run jq -r '.skills["tdd"].version' "$ALL/.coding-crew/manifest.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

# ─── nothing installed that no agent runs ────────────────────────────────────
#
# Every installed word is a word some agent may read at runtime, so a developer
# README and a retired reference are not inert: they are exploration bait in a
# directory the model lists. These assert the crew-afk install ships neither; the
# prune below sweeps an older install's copies.

@test "crew-afk install ships no developer README in the skill tree" {
  [ -f "$ALL/.claude/skills/crew-afk/SKILL.md" ]
  [ ! -f "$ALL/.claude/skills/crew-afk/scripts/README.md" ]
}

@test "crew-afk install ships no verification reference (verify-worktree.sh is the policy)" {
  [ ! -f "$ALL/.claude/skills/crew-afk/references/verification.md" ]
  # solve-issue's own verification reference is a different file and still ships.
  [ -f "$ALL/.claude/skills/solve-issue/references/verification.md" ]
}

@test "to-issues installs references/ beside SKILL.md for every platform" {
  local skill_md dir count=0
  while IFS= read -r skill_md; do
    dir=$(dirname "$skill_md")
    [ ! -e "$dir/references/github-publish.md" ]
    [ ! -e "$dir/references/rerun.md" ]
    [ -f "$dir/references/expand-contract.md" ]
    count=$((count + 1))
  done < <(find "$ALL" -path '*/skills/to-issues/SKILL.md')
  [ "$count" -eq "${#PLATFORMS[@]}" ]
}

# ─── an installed tree is an exact copy of what the install wrote ────────────
#
# No hand list of retired files: whatever a skill root or asset tree holds that this
# run did not write is removed, then any directory left empty.

@test "--update prunes a file to-issues no longer ships, keeping every shipped file" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  local dir="$TEMP_DIR/.claude/skills/to-issues"
  echo "raw gh publish path" > "$dir/references/github-publish.md"
  local m="$TEMP_DIR/.coding-crew/manifest.json"
  jq '.skills["to-issues"].version = "0.0.0"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  [ ! -e "$dir/references/github-publish.md" ]
  [ -f "$dir/SKILL.md" ]
  [ -f "$dir/references/expand-contract.md" ]
  [[ "$output" == *".claude/skills/to-issues/references/github-publish.md (removed)"* ]]
}

@test "a plain re-install prunes a planted file and the directory it leaves empty, never the skill root" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  local dir="$TEMP_DIR/.claude/skills/tdd"
  echo stale > "$dir/stale.md"
  mkdir -p "$dir/old/deeper"
  echo stale > "$dir/old/deeper/gone.md"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ]
  [ ! -e "$dir/stale.md" ]
  [ ! -e "$dir/old" ]
  [ -f "$dir/SKILL.md" ]
  [[ "$output" == *".claude/skills/tdd/stale.md (removed)"* ]]
  [[ "$output" == *".claude/skills/tdd/old/deeper/gone.md (removed)"* ]]
}

@test "the prune keeps every scripts[] file a skill declares" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  echo stale > "$TEMP_DIR/.claude/skills/solve-issue/scripts/retired.sh"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  [ ! -e "$TEMP_DIR/.claude/skills/solve-issue/scripts/retired.sh" ]
  local script
  while IFS= read -r script; do
    [ -x "$TEMP_DIR/.claude/skills/solve-issue/scripts/$script" ]
  done < <(jq -r '.skills["solve-issue"].scripts[]' registry.json)
}

@test "re-installing crew-afk prunes its asset tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  echo "// deleted module" > "$TEMP_DIR/.coding-crew/crew-afk/lib/retired.mjs"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/crew-afk/lib/retired.mjs" ]
  [ -f "$TEMP_DIR/.coding-crew/crew-afk/lib/dispatch.mjs" ]
  [[ "$output" == *".coding-crew/crew-afk/lib/retired.mjs (removed)"* ]]
}

@test "the prune leaves files outside the skill root and asset dests alone" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill tdd >/dev/null
  echo '{"tracker":{"kind":"local"}}' > "$TEMP_DIR/.coding-crew/config.json"
  echo keep > "$TEMP_DIR/.coding-crew/user-note.md"
  local other
  other=$(dirname "$(find "$TEMP_DIR" -path '*/tdd/SKILL.md' -not -path '*/.claude/*' | head -1)")
  [ -n "$other" ]
  echo keep > "$other/planted.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  [ -f "$TEMP_DIR/.coding-crew/config.json" ]
  [ -f "$TEMP_DIR/.coding-crew/manifest.json" ]
  [ -f "$TEMP_DIR/.coding-crew/user-note.md" ]
  [ -f "$other/planted.md" ]
}

@test "solve-issue and crew-afk both get write-commands-cache.sh; only crew-afk gets discover-commands.sh" {
  # solve-issue's own agent turn already *is* the model, so it never dispatches a
  # separate prompt-building call — only the shared write side is needed.
  [ -f "$ALL/.claude/skills/solve-issue/scripts/write-commands-cache.sh" ]
  [ ! -f "$ALL/.claude/skills/solve-issue/scripts/discover-commands.sh" ]

  # crew-afk dispatches an agent-less model call (orchestrator/lib/commands.mjs) and
  # needs both halves.
  [ -f "$ALL/.claude/skills/crew-afk/scripts/write-commands-cache.sh" ]
  [ -f "$ALL/.claude/skills/crew-afk/scripts/discover-commands.sh" ]

  # Canonical source is scripts/skill-utils/git-workflow/ for both, not duplicated by
  # hand in either skill's own source-dir.
  [ ! -f "$SCRIPT_DIR/skills/solve-issue/scripts/write-commands-cache.sh" ]
  [ ! -f "$SCRIPT_DIR/skills/crew-afk/scripts/discover-commands.sh" ]
}

@test "direct install is idempotent (produces identical output on repeat runs)" {
  local temp1="$TEMP_DIR/first"
  local temp2="$TEMP_DIR/second"
  mkdir -p "$temp1" "$temp2"
  cd "$SCRIPT_DIR"
  TARGET_REPO="$temp1" ./install.sh claude --skill tdd > /dev/null
  TARGET_REPO="$temp2" ./install.sh claude --skill tdd > /dev/null

  cmp -s "$temp1/.claude/skills/tdd/SKILL.md" "$temp2/.claude/skills/tdd/SKILL.md"
}

@test "registry.json has no crew: strings (colon-form removed)" {
  cd "$SCRIPT_DIR"

  # registry.json must be valid JSON
  run jq . registry.json
  [ "$status" -eq 0 ]

  # No crew: strings anywhere in registry.json
  ! grep -q 'crew:' registry.json
}

@test "registry.json has no agents: the roles ship inside crew-afk" {
  cd "$SCRIPT_DIR"
  run jq -r 'has("agents")' registry.json
  [ "$output" = "false" ]
}

@test "registry.json skill keys crew-afk and crew-grill are present; crew-plan must not exist" {
  cd "$SCRIPT_DIR"

  run jq -r '.skills | keys[]' registry.json
  [ "$status" -eq 0 ]
  # crew-afk and crew-grill must be present
  [[ "$output" == *"crew-afk"* ]]
  [[ "$output" == *"crew-grill"* ]]
  # tdd must exist without crew- prefix
  [[ "$output" == *"tdd"* ]]
  # crew-tdd must not be present
  ! echo "$output" | grep -qxF "crew-tdd"
  # crew-plan must not be present (renamed to crew-grill)
  ! echo "$output" | grep -qxF "crew-plan"
}

@test "reinstalling modified skill reports the update without a diff body" {
  cd "$SCRIPT_DIR"

  # First install
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null

  # Modify the installed file
  echo "# Modified by test" >> "$TEMP_DIR/.claude/skills/tdd/SKILL.md"

  # Reinstall and capture output
  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill tdd"

  # The changed file is named once, marked (updated)
  [[ "$output" =~ "SKILL.md (updated)" ]]
  # No diff body: no unified-diff headers or hunk markers
  [[ ! "$output" =~ "+++ incoming" ]]
  [[ ! "$output" =~ "@@" ]]
}

@test "--skills is the full desired set: a name dropped from the list is uninstalled" {
  cd "$SCRIPT_DIR"

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skills tdd,to-issues,to-prd > /dev/null
  [ -d "$TEMP_DIR/.claude/skills/to-prd" ]
  run jq -r '.skills | has("to-prd")' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" == "true" ]

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skills tdd,to-issues"

  [[ "$output" =~ "pruning to-prd" ]]
  [ ! -d "$TEMP_DIR/.claude/skills/to-prd" ]
  [ -d "$TEMP_DIR/.claude/skills/tdd" ]
  [ -d "$TEMP_DIR/.claude/skills/to-issues" ]
  run jq -r '.skills | has("to-prd")' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" == "false" ]
}

@test "reinstalling an unmodified install reports no updates" {
  cd "$SCRIPT_DIR"

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk > /dev/null

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill crew-afk"

  # Nothing changed on disk, so nothing should be reported as updated
  [[ ! "$output" =~ "(updated)" ]]
}

# ── tracker config: legacy issue-tracker.md → config.json ──────────────────────
# The fixtures are copies of this repo's own pre-migration files.

TRACKER_FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/tracker-config"

_legacy_tracker_repo() {  # <issue-tracker.md fixture> [config.json fixture]
  mkdir -p "$TEMP_DIR/.coding-crew/docs/templates/trackers"
  cp "$TRACKER_FIXTURES/$1" "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
  cp "$SCRIPT_DIR/tracker/docs/local.md" "$SCRIPT_DIR/tracker/docs/github.md" "$TEMP_DIR/.coding-crew/docs/templates/trackers/"
  [ -z "${2:-}" ] || cp "$TRACKER_FIXTURES/$2" "$TEMP_DIR/.coding-crew/config.json"
}

_assert_legacy_tracker_files_gone() {
  [ ! -e "$TEMP_DIR/.coding-crew/docs/issue-tracker.md" ]
  [ ! -e "$TEMP_DIR/.coding-crew/docs/templates/trackers" ]
  [ ! -e "$TEMP_DIR/.coding-crew/docs" ]
}

@test "install migrates a legacy github issue-tracker.md into config.json, keeping afk, and deletes the legacy files" {
  _legacy_tracker_repo issue-tracker-github.md config-afk-only.json
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ]
  run jq -c --slurpfile afk "$TRACKER_FIXTURES/config-afk-only.json" \
    '. == ($afk[0] + {tracker: {kind: "github"}})' "$TEMP_DIR/.coding-crew/config.json"
  [ "$output" = "true" ]
  _assert_legacy_tracker_files_gone
}

@test "install --update migrates a legacy github issue-tracker.md into config.json and deletes the legacy files" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  _legacy_tracker_repo issue-tracker-github.md config-afk-only.json
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  run jq -c --slurpfile afk "$TRACKER_FIXTURES/config-afk-only.json" \
    '. == ($afk[0] + {tracker: {kind: "github"}})' "$TEMP_DIR/.coding-crew/config.json"
  [ "$output" = "true" ]
  _assert_legacy_tracker_files_gone
}

@test "install migrates a legacy issue-tracker.md without front matter to kind local" {
  _legacy_tracker_repo issue-tracker-no-front-matter.md
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  run jq -c . "$TEMP_DIR/.coding-crew/config.json"
  [ "$output" = '{"tracker":{"kind":"local"}}' ]
  _assert_legacy_tracker_files_gone
}

@test "install keeps an existing tracker section unchanged and still deletes the legacy files" {
  _legacy_tracker_repo issue-tracker-github.md
  printf '{"tracker": {"kind": "local"}, "afk": {}}\n' > "$TEMP_DIR/.coding-crew/config.json"
  local before; before=$(cat "$TEMP_DIR/.coding-crew/config.json")
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  [ "$(cat "$TEMP_DIR/.coding-crew/config.json")" = "$before" ]
  _assert_legacy_tracker_files_gone
}

@test "install leaves a legacy front matter naming repo: in place and says repo is no longer supported" {
  _legacy_tracker_repo issue-tracker-github.md config-afk-only.json
  printf -- '---\ntracker: github\nrepo: owner/name\n---\n' > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
  local doc_before cfg_before
  doc_before=$(cat "$TEMP_DIR/.coding-crew/docs/issue-tracker.md")
  cfg_before=$(cat "$TEMP_DIR/.coding-crew/config.json")
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ]
  [[ "$output" == *'`repo` is no longer supported'* ]]
  [[ "$output" == *"$TEMP_DIR/.coding-crew/docs/issue-tracker.md"* ]]
  [ "$(cat "$TEMP_DIR/.coding-crew/docs/issue-tracker.md")" = "$doc_before" ]
  [ "$(cat "$TEMP_DIR/.coding-crew/config.json")" = "$cfg_before" ]
}

@test "a fresh install writes no .coding-crew/docs/ and no tracker section, and installs the tracker docs" {
  [ ! -e "$ALL/.coding-crew/docs" ]
  if [ -f "$ALL/.coding-crew/config.json" ]; then
    run jq -e 'has("tracker")' "$ALL/.coding-crew/config.json"
    [ "$status" -ne 0 ]
  fi
  cmp "$SCRIPT_DIR/tracker/docs/local.md" "$ALL/.coding-crew/tracker/docs/local.md"
  cmp "$SCRIPT_DIR/tracker/docs/github.md" "$ALL/.coding-crew/tracker/docs/github.md"
}

@test "install --update overwrites the tracker docs when a source doc changed" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  echo "stale prose" > "$TEMP_DIR/.coding-crew/tracker/docs/github.md"
  echo "stale prose" > "$TEMP_DIR/.coding-crew/tracker/docs/local.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh --update > /dev/null
  cmp "$SCRIPT_DIR/tracker/docs/local.md" "$TEMP_DIR/.coding-crew/tracker/docs/local.md"
  cmp "$SCRIPT_DIR/tracker/docs/github.md" "$TEMP_DIR/.coding-crew/tracker/docs/github.md"
}

@test "a user-level install deletes the legacy tracker files and writes no tracker section" {
  _legacy_tracker_repo issue-tracker-github.md
  cd "$SCRIPT_DIR"
  HOME="$TEMP_DIR" TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  _assert_legacy_tracker_files_gone
  if [ -f "$TEMP_DIR/.coding-crew/config.json" ]; then
    run jq -e 'has("tracker")' "$TEMP_DIR/.coding-crew/config.json"
    [ "$status" -ne 0 ]
  fi
}

@test "install --user is rejected with an invalid platform error" {
  run ./install.sh --user claude
  [ "$status" -ne 0 ]
}

@test "registry.json registers no doc templates: tracker docs ship in the tracker tree" {
  cd "$SCRIPT_DIR"

  run jq -r '.docs.templates // empty' registry.json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.docs.trees.tracker.source' registry.json)" = "tracker" ]
}

@test "install does not create triage-labels.md in target repo" {
  [ -d "$ALL/.coding-crew" ]
  [ ! -f "$ALL/docs/agents/triage-labels.md" ]
}

# ── Windows: jq that emits CRLF ────────────────────────────────────────────────
# Git Bash's jq writes stdout in text mode, so `jq -r '.skills | keys[]'` yields
# "tdd\r". install.sh used to read that straight into a registry lookup, miss, and
# print "Warning: skill 'tdd' not found in registry ... skipping" — exit 0, nothing
# installed. Stub jq the same way so the guard holds on every platform's CI.

_stub_jq_crlf() {  # prints the bin dir holding a CRLF-emitting jq shim
  local bindir="$TEMP_DIR/bin" real
  real=$(command -v jq)
  mkdir -p "$bindir"
  cat > "$bindir/jq" <<STUB
#!/usr/bin/env bash
# awk, not sed: BSD sed does not expand \\r in a replacement.
"$real" "\$@" | awk '{ printf "%s\r\n", \$0 }'
exit \${PIPESTATUS[0]}
STUB
  chmod +x "$bindir/jq"
  echo "$bindir"
}

@test "install survives a jq that emits CRLF (Windows Git Bash)" {
  cd "$SCRIPT_DIR"
  local bindir
  bindir=$(_stub_jq_crlf)

  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh pi --skill tdd
  [ "$status" -eq 0 ]
  [[ "$output" != *"not found in registry"* ]]
  [ -f "$TEMP_DIR/.pi/skills/tdd/SKILL.md" ]
  # A \r that survived into a path would install to "tdd?" instead
  run bash -c "ls \"$TEMP_DIR/.pi/skills\" | cat -v"
  [[ "$output" != *'^M'* ]]
}

@test "uninstall removes installed files when jq emits CRLF" {
  cd "$SCRIPT_DIR"
  local bindir
  bindir=$(_stub_jq_crlf)
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill tdd >/dev/null
  [ -f "$TEMP_DIR/.pi/skills/tdd/SKILL.md" ]

  PATH="$bindir:$PATH" run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -d "$TEMP_DIR/.pi" ]
}

# ── Windows: the CR strip must not cost a process per call ─────────────────────
# The wrapper above used to be `command jq "$@" | tr -d '\r'` — three processes per
# lookup (subshell, jq, tr) where one will do. install.sh makes ~1,500 jq calls, and
# Git Bash emulates fork(), so on Windows that pipeline was the single largest cost in
# CI: 27+ minutes for a suite that takes 2 elsewhere. Guard the cheap form.

_jq_wrapper() {  # extracts the jq() wrapper from a script into a sourceable file
  local src="$1" out="$2"
  awk '/^ *jq\(\) \{/,/^ *\}/' "$src" > "$out"
  [ -s "$out" ]
}

@test "every jq wrapper strips CR in-shell instead of spawning tr per call" {
  cd "$SCRIPT_DIR"
  local f
  for f in install.sh uninstall.sh scripts/render-skill.sh; do
    _jq_wrapper "$f" "$TEMP_DIR/wrapper.sh"
    run cat "$TEMP_DIR/wrapper.sh"
    [ "$status" -eq 0 ]
    # A pipeline here is the regression: it re-adds two spawns per lookup.
    [[ "$output" != *"| tr"* ]]
    [[ "$output" == *"//\$'\\r'/"* ]]
    # ...and the wrapper only exists where jq actually appends CR, so a jq that
    # already writes LF is called directly rather than through an extra subshell.
    run grep -c "command jq -rn '\"probe\"'" "$f"
    [ "$output" -eq 1 ]
  done
}

@test "the jq wrapper preserves output, exit status and emptiness" {
  cd "$SCRIPT_DIR"
  _jq_wrapper install.sh "$TEMP_DIR/wrapper.sh"
  printf '{"a":["x","y"]}' > "$TEMP_DIR/j.json"

  cat > "$TEMP_DIR/probe.sh" <<PROBE
source "$TEMP_DIR/wrapper.sh"
echo "lines=\$(jq -r '.a[]' "$TEMP_DIR/j.json" | wc -l | tr -d ' ')"
echo "empty=\$(jq -r '.missing // empty' "$TEMP_DIR/j.json" | wc -l | tr -d ' ')"
jq empty "$TEMP_DIR/nope.json" 2>/dev/null
echo "rc=\$?"
jq -r '.a[0]' "$TEMP_DIR/j.json" >/dev/null
echo "okrc=\$?"
PROBE

  run bash "$TEMP_DIR/probe.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lines=2"* ]]
  # Not one blank line: a `while read` loop must iterate zero times.
  [[ "$output" == *"empty=0"* ]]
  # jq's own failure still reaches the caller (`if ! jq empty` is a real guard).
  # Match rc=0 on its own line (with leading newline) to avoid matching okrc=0 as a substring.
  [[ "$output" != *$'\nrc=0'* ]]
  [[ "$output" == *"okrc=0"* ]]
}

@test "a fresh install into an empty repo writes no .coding-crew/scripts/" {
  [ -f "$ALL/.coding-crew/tracker/cli.mjs" ]
  [ ! -e "$ALL/.coding-crew/scripts" ]
}

# ── the shared tracker CLI (.coding-crew/tracker/) ─────────────────────────────
# Installed on every install, whichever skill, since to-issues / to-prd / solve-issue reach the
# tracker through it without crew-afk; mechanism, so always overwritten, and removed by uninstall.

@test "install of a skill without crew-afk ships the tracker CLI, which runs" {
  local dir; dir="$(shared_installed to-issues)"
  [ -f "$dir/.coding-crew/tracker/cli.mjs" ]
  [ ! -d "$dir/.coding-crew/crew-afk" ]
  cd "$dir"
  run node .coding-crew/tracker/cli.mjs prd --feature-slug x
  [ "$status" -eq 3 ]
}

@test "re-running install overwrites the tracker tree, dropping files the source no longer has" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  echo "// stale" > "$TEMP_DIR/.coding-crew/tracker/cli.mjs"
  echo "// retired" > "$TEMP_DIR/.coding-crew/tracker/retired.mjs"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  cmp -s "$SCRIPT_DIR/tracker/cli.mjs" "$TEMP_DIR/.coding-crew/tracker/cli.mjs"
  [ ! -e "$TEMP_DIR/.coding-crew/tracker/retired.mjs" ]
}

@test "--update refreshes the tracker tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  echo "// stale" > "$TEMP_DIR/.coding-crew/tracker/local.mjs"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  cmp -s "$SCRIPT_DIR/tracker/local.mjs" "$TEMP_DIR/.coding-crew/tracker/local.mjs"
}

@test "uninstall removes the tracker tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/tracker" ]
}

@test "installed crew-afk imports the one shared tracker copy, and an older install's lib/trackers/ is swept" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/.coding-crew/crew-afk/lib/trackers"
  echo "// old" > "$TEMP_DIR/.coding-crew/crew-afk/lib/trackers/github.mjs"
  echo "// old" > "$TEMP_DIR/.coding-crew/crew-afk/lib/tracker-config.mjs"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  [ ! -e "$TEMP_DIR/.coding-crew/crew-afk/lib/trackers" ]
  [ ! -e "$TEMP_DIR/.coding-crew/crew-afk/lib/tracker-config.mjs" ]
  run grep -rl "tracker" "$TEMP_DIR/.coding-crew/crew-afk/lib" --include='tracker*.mjs'
  [ "$output" = "$TEMP_DIR/.coding-crew/crew-afk/lib/tracker.mjs" ]
  # Its imports resolve against .coding-crew/tracker/ — the same module the CLI loads.
  run node --input-type=module -e "
    const a = await import('$TEMP_DIR/.coding-crew/crew-afk/lib/tracker.mjs');
    const b = await import('$TEMP_DIR/.coding-crew/tracker/index.mjs');
    if (a.getTracker !== b.getTracker) process.exit(1);
    const t = await a.getTracker('$TEMP_DIR');
    process.exit(typeof t.listFeatureIssues === 'function' ? 0 : 1);"
  [ "$status" -eq 0 ]
}
