#!/usr/bin/env bats

# scripts/render-skill.sh's shared fragments: the text between a `<!-- fragment:<key> -->` and
# `<!-- /fragment:<key> -->` line pair in a committed SKILL.md is skills/_shared/fragments/<key>.md, so a
# fragment used by several skills (e.g. the "Tracker Configuration" preamble to-issues/to-prd/upgrade-deps
# all used to copy-paste independently) has exactly one source instead of one per skill.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RENDER="$REPO_ROOT/scripts/render-skill.sh"

# The probe skill lives in a per-test render tree (render-skill.sh resolves registry.json, skills/ and
# lib/ from its own location) whose registry names only the probe, never under the real skills/: bats -j
# runs tests concurrently, and the renderer rewrites the tree it runs in.
FIXTURE_NAME="__render_skill_fragment_probe__"

setup() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/scripts" "$TREE/skills/$FIXTURE_NAME" "$TREE/lib/probe-lib"
  cp "$RENDER" "$TREE/scripts/render-skill.sh"
  jq -n --arg s "$FIXTURE_NAME" '{skills: {($s): {libs: ["probe-lib"]}}}' > "$TREE/registry.json"
  PROBE_RENDER="$TREE/scripts/render-skill.sh"
  FIXTURE_SKILL_DIR="$TREE/skills/$FIXTURE_NAME"
  SHARED_DIR="$TREE/skills/_shared/fragments"
  mkdir -p "$SHARED_DIR"
  echo "Shared content." > "$SHARED_DIR/shared-only.md"
  echo "#!/bin/sh" > "$TREE/lib/probe-lib/tool.sh"
  chmod +x "$TREE/lib/probe-lib/tool.sh"
  {
    echo "# Probe"
    echo ""
    echo "<!-- fragment:shared-only -->"
    echo "stale text"
    echo "<!-- /fragment:shared-only -->"
    echo ""
    echo "## Process"
  } > "$FIXTURE_SKILL_DIR/SKILL.md"
}

@test "the text between a marker pair is rewritten from the fragment, the markers kept" {
  run bash "$PROBE_RENDER"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$FIXTURE_SKILL_DIR/SKILL.md")" = "$(printf '# Probe\n\n<!-- fragment:shared-only -->\nShared content.\n<!-- /fragment:shared-only -->\n\n## Process')" ]
}

@test "scripts/<lib> becomes an exact copy of lib/<lib>: files added, removed and exec bits kept" {
  mkdir -p "$FIXTURE_SKILL_DIR/scripts/probe-lib"
  echo gone > "$FIXTURE_SKILL_DIR/scripts/probe-lib/old.sh"
  mkdir -p "$TREE/lib/probe-lib/docs" && echo doc > "$TREE/lib/probe-lib/docs/a.md"
  run bash "$PROBE_RENDER"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  diff -r "$TREE/lib/probe-lib" "$FIXTURE_SKILL_DIR/scripts/probe-lib"
  [ -x "$FIXTURE_SKILL_DIR/scripts/probe-lib/tool.sh" ]
  [ ! -x "$FIXTURE_SKILL_DIR/scripts/probe-lib/docs/a.md" ]
}

@test "the renderer takes no arguments" {
  run bash "$PROBE_RENDER" "$FIXTURE_NAME"
  [ "$status" -eq 2 ]
}

@test "a {{ left in a body fails the render, naming the file" {
  echo "Run on {{PLATFORM}}." >> "$FIXTURE_SKILL_DIR/SKILL.md"
  run bash "$PROBE_RENDER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpanded placeholder"*"skills/$FIXTURE_NAME/SKILL.md"* ]]
}

@test "a missing fragment is a hard error naming the file" {
  rm "$SHARED_DIR/shared-only.md"
  run bash "$PROBE_RENDER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"skills/$FIXTURE_NAME/SKILL.md"*"fragment 'shared-only'"* ]]
}

@test "an unmatched marker is a hard error naming the file" {
  local body
  for body in $'<!-- fragment:shared-only -->\ntext' $'text\n<!-- /fragment:shared-only -->' \
    $'<!-- fragment:shared-only -->\n<!-- fragment:shared-only -->\n<!-- /fragment:shared-only -->'; do
    printf '%s\n' "$body" > "$FIXTURE_SKILL_DIR/SKILL.md"
    run bash "$PROBE_RENDER"
    [ "$status" -ne 0 ] || { echo "not caught: $body"; return 1; }
    [[ "$output" == *"skills/$FIXTURE_NAME/SKILL.md"* ]] || { echo "$output"; return 1; }
  done
}

# ─── the real shared fragments ───────────────────────────────────────────────────

@test "skills/_shared/fragments holds one file per fragment and no subdirectories" {
  [ -f "$REPO_ROOT/skills/_shared/fragments/tracker-configuration.md" ]
  run find "$REPO_ROOT/skills/_shared/fragments" -mindepth 1 -type d
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the text between every marker pair in a committed SKILL.md is byte-identical to its fragment" {
  # A skill whose fragment text differed would be saying the same thing twice, differently.
  local f key n=0 between
  while IFS= read -r f; do
    for key in $(sed -n 's/^<!-- fragment:\([A-Za-z0-9_-]*\) -->$/\1/p' "$f" | sort -u); do
      between=$(awk -v k="$key" '$0 == "<!-- /fragment:" k " -->" {f=0} f; $0 == "<!-- fragment:" k " -->" {f=1}' "$f")
      [ "$between" = "$(cat "$REPO_ROOT/skills/_shared/fragments/$key.md")" ] || {
        echo "${f#"$REPO_ROOT/"}: the text between its $key markers is not the fragment:" >&2
        diff <(cat "$REPO_ROOT/skills/_shared/fragments/$key.md") <(printf '%s\n' "$between") >&2
        return 1
      }
      n=$((n + 1))
    done
  done < <(find "$REPO_ROOT/skills" -name SKILL.md | LC_ALL=C sort)
  [ "$n" -ge 8 ]
}

@test "to-issues, to-prd, upgrade-deps and solve-issue carry the tracker-configuration fragment" {
  local skill body
  for skill in to-issues to-prd upgrade-deps solve-issue; do
    body="$REPO_ROOT/skills/$skill/SKILL.md"
    grep -qxF '<!-- fragment:tracker-configuration -->' "$body" || {
      echo "$skill has no tracker-configuration markers" >&2; return 1; }
    grep -qxF '## Tracker Configuration' "$body"
    grep -qF 'node "$TRACKER" config' "$body"
    ! grep -qF 'issue-tracker.md' "$body" || { echo "$skill still names issue-tracker.md" >&2; return 1; }
  done
}

@test "no {{FRAGMENT: line is left under skills/" {
  ! grep -rn '{{FRAGMENT:' "$REPO_ROOT/skills" || false
}

@test "the tracker-configuration fragment asks configure-tracker on configured=no only interactively, else proceeds as local" {
  local f="$REPO_ROOT/skills/_shared/fragments/tracker-configuration.md"
  grep -qF 'node "$TRACKER" config' "$f"
  grep -qF 'configured=no' "$f"
  grep -qF 'configure-tracker' "$f"
  grep -qiF 'interactive run' "$f"
  grep -qF -- '-p' "$f"
  grep -qF 'proceed as `local`' "$f"
  grep -qF '<skill-dir>/scripts/tracker/cli.mjs' "$f"
  grep -qF '<skill-dir>/scripts/tracker/docs/<kind>.md' "$f"
  ! grep -qF '.coding-crew/' "$f"
  ! grep -q 'issue-tracker.md' "$f"
}
