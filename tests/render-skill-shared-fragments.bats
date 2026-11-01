#!/usr/bin/env bats

# scripts/render-skill.sh's shared fragments: the text between a `<!-- fragment:<key> -->` and
# `<!-- /fragment:<key> -->` line pair in a committed SKILL.md is skills/_shared/fragments/<key>.md, so a
# fragment used by several skills (e.g. the "Tracker Configuration" preamble to-issues/to-prd/upgrade-deps
# all used to copy-paste independently) has exactly one source instead of one per skill.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RENDER="$REPO_ROOT/scripts/render-skill.sh"

# The probe skill lives in a per-test render tree (render-skill.sh resolves registry.json and skills/ from
# its own location) whose registry names only the probe, never under the real skills/: bats -j
# runs tests concurrently, and the renderer rewrites the tree it runs in.
FIXTURE_NAME="__render_skill_fragment_probe__"

setup() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/scripts" "$TREE/skills/$FIXTURE_NAME"
  cp "$RENDER" "$TREE/scripts/render-skill.sh"
  jq -n --arg s "$FIXTURE_NAME" '{skills: {($s): {}}}' > "$TREE/registry.json"
  PROBE_RENDER="$TREE/scripts/render-skill.sh"
  FIXTURE_SKILL_DIR="$TREE/skills/$FIXTURE_NAME"
  SHARED_DIR="$TREE/skills/_shared/fragments"
  mkdir -p "$SHARED_DIR"
  echo "Shared content." > "$SHARED_DIR/shared-only.md"
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

@test "the tracker-configuration fragment asks configure-tracker on configured=no only interactively, else proceeds as local" {
  local f="$REPO_ROOT/skills/_shared/fragments/tracker-configuration.md"
  grep -qF 'node "$TRACKER" config' "$f"
  grep -qF 'configured=no' "$f"
  grep -qF 'configure-tracker' "$f"
  grep -qiF 'interactive run' "$f"
  grep -qF -- '-p' "$f"
  grep -qF 'proceed as `local`' "$f"
  grep -qF '<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs' "$f"
  grep -qF '<skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md' "$f"
  ! grep -qF '.coding-crew/' "$f"
  ! grep -q 'issue-tracker.md' "$f"
}

@test "every skill that depends on coding-crew-lib, but solve-feature, carries the missing-library fragment, and no other skill does" {
  local skill body want got
  want=$(jq -r '.skills | to_entries[] | select((.value.deps // []) | index("coding-crew-lib")) | .key | select(. != "solve-feature")' \
    "$REPO_ROOT/registry.json" | LC_ALL=C sort)
  [ "$(wc -l <<< "$want" | tr -d ' ')" -eq 14 ] || { echo "$want"; return 1; }
  got=$(cd "$REPO_ROOT/skills" && grep -lxF '<!-- fragment:missing-library -->' */SKILL.md | sed 's#/SKILL.md##' | LC_ALL=C sort)
  [ "$got" = "$want" ] || { diff <(echo "$want") <(echo "$got"); return 1; }
}

@test "the missing-library fragment stops when coding-crew-lib is absent and names its install at the same scope, or install.sh" {
  local f="$REPO_ROOT/skills/_shared/fragments/missing-library.md"
  grep -qF '<skill-dir>/../coding-crew-lib' "$f"
  grep -qF '`coding-crew-lib`' "$f"
  grep -qF 'npx skills add <that source> -s coding-crew-lib' "$f"
  ! grep -qF 'ypxing/coding-crew' "$f"
  grep -qF -- '`-g`' "$f"
  grep -qF 'install.sh' "$f"
  grep -qi 'stop' "$f"
}

# light_path <skill> — the rendered light path, from its first marker to its last, markers dropped and blank runs squeezed.
light_path() {
  sed -n '/^<!-- fragment:light-path -->$/,/^<!-- \/fragment:light-path-outcome -->$/p' "$REPO_ROOT/skills/$1/SKILL.md" \
    | grep -v '^<!-- /\?fragment:' | cat -s
}

@test "crew-grill and crew-brainstorm render the whole light path, its four checks from light-path-checks; crew-triage renders the checks alone" {
  local d="$REPO_ROOT/skills/_shared/fragments" skill want
  [ "$(grep -cE '^[1-4]\. \*\*' "$d/light-path-checks.md")" -eq 4 ]
  ! grep -qE '^[1-4]\. \*\*' "$d/light-path.md" "$d/light-path-outcome.md" || false
  want=$(printf '%s\n\n%s\n\n%s\n' "$(cat "$d/light-path.md")" "$(cat "$d/light-path-checks.md")" "$(cat "$d/light-path-outcome.md")")
  for skill in crew-grill crew-brainstorm; do
    [ "$(light_path "$skill")" = "$want" ] || { diff <(echo "$want") <(light_path "$skill"); return 1; }
  done
  local t="$REPO_ROOT/skills/crew-triage/SKILL.md"
  grep -qxF '<!-- fragment:light-path-checks -->' "$t"
  grep -qxF '<!-- fragment:untrusted-text -->' "$t"
  ! grep -qE '^<!-- fragment:light-path(-outcome)? -->$' "$t" || false
}

@test "crew-grill and crew-triage both render the worth-asking fragment, which names neither skill" {
  local f="$REPO_ROOT/skills/_shared/fragments/worth-asking.md" skill
  grep -qF 'Would a staff engineer on this team need to ask this' "$f"
  [ "$(grep -cE '^- \*\*(Discoverable|Already answered|Testable|Conventional|Analysis|Deferrable|Rubber-stamp)\*\* — ' "$f")" -eq 7 ]
  ! grep -qiE 'crew-|triage|grill|gate' "$f" || false
  for skill in crew-grill crew-triage; do
    grep -qxF '<!-- fragment:worth-asking -->' "$REPO_ROOT/skills/$skill/SKILL.md"
    grep -qxF '<!-- /fragment:worth-asking -->' "$REPO_ROOT/skills/$skill/SKILL.md"
  done
}

@test "crew-grill and crew-brainstorm both render the other-repos fragment, which names no consumer and no downstream tool" {
  local f="$REPO_ROOT/skills/_shared/fragments/other-repos.md" skill
  grep -qF 'checkout path' "$f"
  grep -qF 'read-only' "$f"
  grep -qF '`owner/repo`' "$f"
  ! grep -qiE 'crew-|grill|brainstorm|to-issues|to-prd|solve-|PRD' "$f" || false
  for skill in crew-grill crew-brainstorm; do
    grep -qxF '<!-- fragment:other-repos -->' "$REPO_ROOT/skills/$skill/SKILL.md"
    grep -qxF '<!-- /fragment:other-repos -->' "$REPO_ROOT/skills/$skill/SKILL.md"
  done
}

@test "light-path-checks: a plan that changes more than one repo is not one slice" {
  grep -qE '^2\. \*\*One slice\*\* — .*more than one repo is not one slice' "$REPO_ROOT/skills/_shared/fragments/light-path-checks.md"
}

@test "other-repos: from a folder that is no git repo, the user names the repos and the home repo, and tracker ops run inside each repo" {
  local f="$REPO_ROOT/skills/_shared/fragments/other-repos.md"
  grep -qF 'plan and issues (the **home repo**)' "$f"
  grep -qF 'cd <repo> && node' "$f"
  grep -qxF '<!-- fragment:other-repos -->' "$REPO_ROOT/skills/to-issues/SKILL.md"
  grep -qF 'cd <repo> && node' "$REPO_ROOT/skills/_shared/fragments/light-path.md"
}
