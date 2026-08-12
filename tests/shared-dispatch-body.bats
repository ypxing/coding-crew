#!/usr/bin/env bats

# P2: every platform that still ships a *prose* orchestrator shares ONE body.
#
# They used to be three ~5,000-word files that were 85–90% identical, and they
# drifted: three of the four variants declared `review → close → merge` and ran
# close-issue.sh before merge-branches.sh, so a merge conflict moved the issue to
# done/ with the work unmerged (audit finding 3). Parity by review does not hold at
# that size, so parity is now structural: one `dispatch.SKILL.md` plus a small
# per-platform fragment set, inlined at install time by scripts/render-skill.sh.
#
# pi and codex have since cut over to the orchestrator program, so this suite's subject
# is shrinking towards nothing (see tests/crew-afk-launcher.bats). It still guards the
# fragment mechanism for what is left, and the single-platform case is guarded explicitly
# below so nothing here can pass by iterating an empty list. Prose assertions live in the
# other suites and now run against the rendered body.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_DIR="$REPO_ROOT/skills/crew-afk"
RENDER="$REPO_ROOT/scripts/render-skill.sh"
DISPATCH_PLATFORMS=("${AFK_PROSE_DISPATCH_VARIANTS[@]}")

# ─── one body, no per-platform copies ────────────────────────────────────────

@test "P2: the prose platform list is not empty (these tests have a subject)" {
  # Every loop below iterates it. An empty list would turn this whole suite green
  # while asserting nothing — the failure mode of a cutover that forgot the last step.
  # When the list finally empties, delete this suite (issue 05) rather than the guard.
  [ "${#DISPATCH_PLATFORMS[@]}" -ge 1 ]
}

@test "P2: the deleted per-platform bodies have not come back" {
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    if [ -f "$AFK_DIR/$platform.SKILL.md" ]; then
      echo "$platform.SKILL.md exists again — the shared body has been forked" >&2
      return 1
    fi
  done
}

@test "P2: registry points every dispatch platform at the same body" {
  local bodies=()
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    body=$(jq -r --arg p "$platform" '.skills["crew-afk"].body[$p] // empty' "$REPO_ROOT/registry.json")
    [ -n "$body" ] || { echo "no body mapping for $platform" >&2; return 1; }
    [ -f "$AFK_DIR/$body" ] || { echo "body $body for $platform does not exist" >&2; return 1; }
    bodies+=("$body")
  done
  local first="${bodies[0]}" b
  for b in "${bodies[@]}"; do
    [ "$b" = "$first" ] || { echo "body mapping diverged: $b != $first" >&2; return 1; }
  done
}

@test "P2: claude keeps its own body (native Agent tool, batches of 3)" {
  run jq -r '.skills["crew-afk"].body.claude // "none"' "$REPO_ROOT/registry.json"
  [ "$output" = "none" ]
  grep -q 'AFK Issue Sprint — Claude Code' "$AFK_DIR/SKILL.md"
}

# ─── rendering ───────────────────────────────────────────────────────────────

@test "P2: every platform renders, with no placeholder left behind" {
  for platform in claude "${DISPATCH_PLATFORMS[@]}"; do
    rendered=$(afk_variant "$platform")
    [ -s "$rendered" ] || { echo "$platform rendered empty" >&2; return 1; }
    if grep -n '{{' "$rendered"; then
      echo "$platform still contains a placeholder" >&2
      return 1
    fi
  done
}

@test "P2: each rendered body identifies its own platform" {
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    # The heading comes from the intro fragment, so a body that names another
    # platform means the fragment set was copied rather than written.
    run grep -qi "^# AFK Issue Sprint — $platform$" "$(afk_variant "$platform")"
    [ "$status" -eq 0 ] || { echo "$platform body does not name itself" >&2; return 1; }
  done
}

@test "P2: {{PLATFORM}} reaches the squash call for each platform" {
  # The launcher platforms are absent by design: their orchestrator is a program, which
  # passes --platform <p> to squash-commits.sh itself (orchestrator/lib/loop.mjs).
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    run grep -q "squash-commits.sh\" --platform $platform" "$(afk_variant "$platform")"
    [ "$status" -eq 0 ] || { echo "$platform did not get {{PLATFORM}} substituted" >&2; return 1; }
  done
}

@test "P2: every fragment the shared body asks for exists for every platform" {
  local keys
  keys=$(grep -o '{{FRAGMENT:[A-Za-z0-9_-]*}}' "$AFK_DIR/dispatch.SKILL.md" \
         | sed 's/{{FRAGMENT://; s/}}//' | sort -u)
  [ -n "$keys" ]
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    for key in $keys; do
      [ -f "$AFK_DIR/fragments/$platform/$key.md" ] || {
        echo "missing fragments/$platform/$key.md" >&2; return 1; }
    done
  done
}

@test "P2: a missing fragment fails the render loudly" {
  # A silently-skipped fragment would ship a body with a hole in it, so the
  # renderer must refuse rather than emit the placeholder or an empty line.
  frag="$AFK_DIR/fragments/${DISPATCH_PLATFORMS[0]}/intro.md"
  cp "$frag" "$BATS_TEST_TMPDIR/intro.md"
  rm "$frag"
  run bash "$RENDER" crew-afk "${DISPATCH_PLATFORMS[0]}"
  cp "$BATS_TEST_TMPDIR/intro.md" "$frag"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fragment 'intro'"* ]]
}

@test "P2: no fragment file is left unused by the shared body" {
  local keys
  keys=$(grep -o '{{FRAGMENT:[A-Za-z0-9_-]*}}' "$AFK_DIR/dispatch.SKILL.md" \
         | sed 's/{{FRAGMENT://; s/}}//' | sort -u)
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    for f in "$AFK_DIR/fragments/$platform"/*.md; do
      key=$(basename "$f" .md)
      echo "$keys" | grep -qx "$key" || {
        echo "fragments/$platform/$key.md is never inlined — dead prose" >&2; return 1; }
    done
  done
}

# ─── parity that used to be maintained by hand ───────────────────────────────

@test "P2: the dispatch platforms share an identical section structure" {
  # Everything outside a fragment is literally one source, so the top-level
  # section sequence must match exactly. A divergence means someone moved a step
  # into a fragment, which is how the close-before-merge bug spread.
  #
  # With one prose platform left this compares the body to itself, which still catches
  # an H2 that a *fragment* introduces — the divergence this was written for.
  local first="${DISPATCH_PLATFORMS[0]}" platform other
  first_h2=$(grep '^## ' "$(afk_variant "$first")")
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    other=$(grep '^## ' "$(afk_variant "$platform")")
    [ "$first_h2" = "$other" ] || {
      echo "section structure differs between $first and $platform" >&2
      diff <(echo "$first_h2") <(echo "$other") >&2 || true
      return 1
    }
  done
}

@test "P2: every dispatch platform states the same pipeline order" {
  local line=""
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    this=$(grep -m1 'Pipeline order per branch:' "$(afk_variant "$platform")")
    [ -n "$this" ] || { echo "$platform has no pipeline order line" >&2; return 1; }
    if [ -n "$line" ]; then
      [ "$line" = "$this" ] || { echo "$platform disagrees on pipeline order" >&2; return 1; }
    fi
    line="$this"
  done
  [[ "$line" == *"merge → close"* ]]
}

@test "P2: fragments hold only platform-specific text, not the whole body" {
  # The point of P2 is that the shared body carries the bulk. If a fragment set
  # grows past a third of the body, the split has stopped paying for itself and
  # the platforms are forking again a paragraph at a time.
  body_words=$(wc -w < "$AFK_DIR/dispatch.SKILL.md")
  for platform in "${DISPATCH_PLATFORMS[@]}"; do
    frag_words=$(cat "$AFK_DIR/fragments/$platform"/*.md | wc -w)
    [ "$frag_words" -lt "$((body_words / 3))" ] || {
      echo "$platform fragments are $frag_words words against a $body_words-word body" >&2
      return 1
    }
  done
}

# ─── install-time behaviour ──────────────────────────────────────────────────

@test "P2: install writes the rendered body and ships no build inputs" {
  temp=$(mktemp -d)
  cd "$temp" && git init -q .
  cd "$REPO_ROOT"
  TARGET_REPO="$temp" ./install.sh pi --skill crew-afk >/dev/null

  installed="$temp/.pi/skills/crew-afk/SKILL.md"
  [ -f "$installed" ]
  diff "$installed" "$(afk_variant pi)"
  # Fragments and alternate bodies are build inputs — they must not be installed.
  [ ! -d "$temp/.pi/skills/crew-afk/fragments" ]
  [ ! -f "$temp/.pi/skills/crew-afk/dispatch.SKILL.md" ]
  run bash -c "ls $temp/.pi/skills/crew-afk/*.SKILL.md 2>/dev/null"
  [ -z "$output" ]
  rm -rf "$temp"
}

@test "P2: install prunes a fragments dir and body left by an older install" {
  temp=$(mktemp -d)
  cd "$temp" && git init -q .
  cd "$REPO_ROOT"
  TARGET_REPO="$temp" ./install.sh pi --skill crew-afk >/dev/null
  # Simulate the pre-P2 layout, which copied every file in the skill directory.
  mkdir -p "$temp/.pi/skills/crew-afk/fragments/pi"
  echo stale > "$temp/.pi/skills/crew-afk/fragments/pi/intro.md"
  echo stale > "$temp/.pi/skills/crew-afk/dispatch.SKILL.md"
  echo stale > "$temp/.pi/skills/crew-afk/codex.SKILL.md"

  TARGET_REPO="$temp" ./install.sh pi --skill crew-afk >/dev/null
  [ ! -d "$temp/.pi/skills/crew-afk/fragments" ]
  [ ! -f "$temp/.pi/skills/crew-afk/dispatch.SKILL.md" ]
  [ ! -f "$temp/.pi/skills/crew-afk/codex.SKILL.md" ]
  rm -rf "$temp"
}
