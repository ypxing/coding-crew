#!/usr/bin/env bats

# Tracer bullet test - verify basic install creates expected file

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "install skill creates SKILL.md at expected path" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd

  # Verify the skill file was created
  [ -f "$TEMP_DIR/.claude/skills/tdd/SKILL.md" ]
}

@test "protocol substitution removes {{PROTOCOL}} placeholder" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer

  # Verify the agent file exists
  [ -f "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]

  # Verify no {{PROTOCOL}} literal remains in the installed file
  ! grep -q '{{PROTOCOL}}' "$TEMP_DIR/.claude/agents/crew-code-reviewer.md"
}

@test "manifest contains correct skill name and version after install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd

  # Verify manifest was created
  [ -f "$TEMP_DIR/.coding-crew/manifest.json" ]

  # Verify skill entry exists
  run jq -r '.skills["tdd"].version' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "installing crew-afk installs agent-deps (crew-coder and crew-code-reviewer)" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  # Verify both agent files were installed
  [ -f "$TEMP_DIR/.claude/agents/crew-coder.md" ]
  [ -f "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]

  # Verify manifest contains both agents
  run jq -r '.agents["crew-coder"].version' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run jq -r '.agents["crew-code-reviewer"].version' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
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

@test "registry.json agent keys use crew- prefix" {
  cd "$SCRIPT_DIR"

  run jq -r '.agents | keys[]' registry.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"crew-coder"* ]]
  [[ "$output" == *"crew-code-reviewer"* ]]
  # Old keys must not be present
  ! echo "$output" | grep -qxF "coder"
  ! echo "$output" | grep -qxF "code-reviewer"
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

@test "crew-grill skill is installed to correct directory" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-grill

  [ -f "$TEMP_DIR/.claude/skills/crew-grill/SKILL.md" ]
}

@test "crew-grill SKILL.md contains correct name field" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-grill

  grep -q 'name: crew-grill' "$TEMP_DIR/.claude/skills/crew-grill/SKILL.md"
}

@test "crew-grill copilot skill is installed to correct directory" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-grill

  [ -f "$TEMP_DIR/.copilot/skills/crew-grill/SKILL.md" ]
}

@test "crew-brainstorm skill is installed to correct directory (claude)" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-brainstorm

  [ -f "$TEMP_DIR/.claude/skills/crew-brainstorm/SKILL.md" ]
}

@test "crew-brainstorm skill is installed to correct directory (copilot)" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-brainstorm

  [ -f "$TEMP_DIR/.copilot/skills/crew-brainstorm/SKILL.md" ]
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

@test "reinstalling an unmodified install reports no updates" {
  cd "$SCRIPT_DIR"

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk > /dev/null

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill crew-afk"

  # Nothing changed on disk, so nothing should be reported as updated
  [[ ! "$output" =~ "(updated)" ]]
}

@test "install creates .coding-crew/docs/issue-tracker.md in target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude

  [ -f "$TEMP_DIR/.coding-crew/docs/issue-tracker.md" ]
}

@test "reinstall does not overwrite existing .coding-crew/docs/issue-tracker.md" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude > /dev/null

  # Modify the installed file
  echo "custom content" > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"

  # Reinstall
  TARGET_REPO="$TEMP_DIR" ./install.sh claude > /dev/null

  # Verify custom content was preserved (not overwritten)
  grep -q "custom content" "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
}

@test "install --user is rejected with an invalid platform error" {
  run ./install.sh --user claude
  [ "$status" -ne 0 ]
}

@test "registry.json docs section registers tracker template source" {
  cd "$SCRIPT_DIR"

  run jq -r '.docs.templates["issue-tracker"].source // empty' registry.json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "install does not create triage-labels.md in target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude > /dev/null

  [ ! -f "$TEMP_DIR/docs/agents/triage-labels.md" ]
}

@test "crew-address-findings skill is installed to correct directory" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-address-findings

  # Verify the skill file was created at the correct path
  [ -f "$TEMP_DIR/.claude/skills/crew-address-findings/SKILL.md" ]
}

@test "crew-address-findings SKILL.md contains correct name field" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-address-findings

  # Verify the installed SKILL.md has name: crew-address-findings
  grep -q 'name: crew-address-findings' "$TEMP_DIR/.claude/skills/crew-address-findings/SKILL.md"
}

@test "address-code-review directory is absent after crew-address-findings install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-address-findings

  # Verify the old address-code-review directory does not exist
  [ ! -d "$TEMP_DIR/.claude/skills/address-code-review/" ]
}

@test "--version latest resolves to a concrete tag in crew.lock" {
  # Stub curl so the test never touches the network: mimic GitHub's
  # /releases/latest -> /releases/tag/<tag> redirect that install.sh follows.
  local bindir="$TEMP_DIR/bin"
  mkdir -p "$bindir"
  cat > "$bindir/curl" <<'STUB'
#!/usr/bin/env bash
echo "https://github.com/ypxing/coding-crew/releases/tag/v2.3.4"
STUB
  chmod +x "$bindir/curl"

  cd "$SCRIPT_DIR"
  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh claude --skill tdd \
    --version latest --registry https://github.com/ypxing/coding-crew
  [ "$status" -eq 0 ]

  run jq -r '.version' "$TEMP_DIR/crew.lock"
  [ "$output" = "v2.3.4" ]
}

@test "--version latest fails loudly when no registry can be determined" {
  local bindir="$TEMP_DIR/bin"
  mkdir -p "$bindir"
  printf '#!/usr/bin/env bash\nexit 22\n' > "$bindir/curl"
  chmod +x "$bindir/curl"

  cd "$SCRIPT_DIR"
  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh claude --skill tdd \
    --version latest --registry https://github.com/ypxing/coding-crew
  [ "$status" -ne 0 ]
  [ ! -f "$TEMP_DIR/crew.lock" ]
}

@test "uninstall leaves no empty platform directories behind" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh >/dev/null
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]

  for dir in .claude .copilot .pi .codex .agents; do
    if [ -d "$TEMP_DIR/$dir" ]; then
      echo "REPO_ROOT was: $TEMP_DIR"
      echo "--- uninstall output ---"
      echo "$output"
      echo "--- leftover $dir ---"
      find "$TEMP_DIR/$dir" | head -5
    fi
    [ ! -d "$TEMP_DIR/$dir" ]
  done
  # .coding-crew survives only because it still holds user-customisable docs
  [ -f "$TEMP_DIR/.coding-crew/docs/issue-tracker.md" ]
}

# ── crew.lock round-trip ───────────────────────────────────────────────────────
# Stubs curl the way the "--version latest" test above does, so none of these
# touch the network.

_stub_curl_latest() {  # $1 = tag to report as the newest release
  local bindir="$TEMP_DIR/bin"
  mkdir -p "$bindir"
  cat > "$bindir/curl" <<STUB
#!/usr/bin/env bash
echo "https://github.com/ypxing/coding-crew/releases/tag/$1"
STUB
  chmod +x "$bindir/curl"
  echo "$bindir"
}

@test "--update on a lockfile already at the latest release is a no-op" {
  local bindir
  bindir=$(_stub_curl_latest v9.9.9)

  cat > "$TEMP_DIR/crew.lock" <<'LOCK'
{
  "registry": "https://github.com/ypxing/coding-crew",
  "version": "v9.9.9",
  "platform": "pi",
  "agents": {},
  "skills": {}
}
LOCK

  cd "$SCRIPT_DIR"
  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh --update
  [ "$status" -eq 0 ]
  # The v-prefix must be normalised on both sides; a mismatch here reinstalls
  # everything on every --update and prints "vv9.9.9".
  [[ "$output" == *"Already at v9.9.9"* ]]
  [[ "$output" != *"vv9.9.9"* ]]
  [[ "$output" != *"Update available"* ]]
}

@test "--version records a v-prefixed tag and the installed platform in crew.lock" {
  local bindir
  bindir=$(_stub_curl_latest v2.3.4)

  cd "$SCRIPT_DIR"
  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh pi --skill tdd \
    --version latest --registry https://github.com/ypxing/coding-crew
  [ "$status" -eq 0 ]

  run jq -r '.version' "$TEMP_DIR/crew.lock"
  [ "$output" = "v2.3.4" ]
  run jq -r '.platform' "$TEMP_DIR/crew.lock"
  [ "$output" = "pi" ]
  # Item versions are objects, so a later --update can read .version back out
  run jq -r '.skills.tdd.version' "$TEMP_DIR/crew.lock"
  [ "$output" != "null" ]
}

@test "--from-lockfile installs the pinned tag without a doubled v and honours platform" {
  cd "$SCRIPT_DIR"
  local pinned
  # tr: a Windows jq appends \r, and a raw CR inside a JSON string would make the
  # fixture itself the bug under test instead of install.sh's handling of it.
  pinned=$(jq -r '.skills.tdd.version' registry.json | tr -d '\r')

  # file:// registry keeps this off the network; version still exercises the
  # v-prefix path that used to build a "vv1.2.3.tar.gz" URL and 404.
  cat > "$TEMP_DIR/crew.lock" <<LOCK
{
  "registry": "file://$SCRIPT_DIR",
  "version": "v1.17.0",
  "platform": "pi",
  "agents": {},
  "skills": { "tdd": { "version": "$pinned" } }
}
LOCK

  TARGET_REPO="$TEMP_DIR" run ./install.sh --from-lockfile
  [ "$status" -eq 0 ]
  [[ "$output" != *"vv1.17.0"* ]]
  [[ "$output" != *"version mismatch"* ]]
  [ -f "$TEMP_DIR/.pi/skills/tdd/SKILL.md" ]
  # platform was "pi": other platforms must not be installed
  [ ! -d "$TEMP_DIR/.claude/skills/tdd" ]
}

@test "--update reads object-form lockfile item versions instead of reinstalling blindly" {
  local bindir
  bindir=$(_stub_curl_latest v9.9.9)
  cd "$SCRIPT_DIR"
  local current
  current=$(jq -r '.skills.tdd.version' registry.json | tr -d '\r')

  cat > "$TEMP_DIR/crew.lock" <<LOCK
{
  "registry": "file://$SCRIPT_DIR",
  "version": "v9.9.9",
  "platform": "pi",
  "agents": {},
  "skills": { "tdd": { "version": "$current" } }
}
LOCK

  # Same version on both sides -> the early "already at latest" exit fires,
  # which is itself the regression guard for the v-prefix comparison.
  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already at v9.9.9"* ]]
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

@test "--from-lockfile installs the skill when jq emits CRLF" {
  cd "$SCRIPT_DIR"
  local bindir pinned
  bindir=$(_stub_jq_crlf)
  pinned=$(jq -r '.skills.tdd.version' registry.json | tr -d '\r')

  cat > "$TEMP_DIR/crew.lock" <<LOCK
{
  "registry": "file://$SCRIPT_DIR",
  "version": "v1.17.0",
  "platform": "pi",
  "agents": {},
  "skills": { "tdd": { "version": "$pinned" } }
}
LOCK

  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh --from-lockfile
  [ "$status" -eq 0 ]
  [[ "$output" != *"not found in registry"* ]]
  [[ "$output" != *"version mismatch"* ]]
  [ -f "$TEMP_DIR/.pi/skills/tdd/SKILL.md" ]
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
  [[ "$output" != *"rc=0"* ]]
  [[ "$output" == *"okrc=0"* ]]
}
