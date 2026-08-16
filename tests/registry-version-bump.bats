#!/usr/bin/env bats

# install.sh --update (both the crew.lock tarball path and the legacy manifest path) decides
# whether to reinstall an agent/skill by comparing registry.json's version field alone — see
# run_update_from_lockfile / run_update in install.sh. If an entry's own effect (scripts[],
# assets, platform-files, agent-deps, deps, install paths) changes without its version also
# changing, every existing --update silently keeps the old files forever, with no error and no
# hint that anything was skipped. That is exactly what shipped in v1.29.0: crew-afk and
# solve-issue each grew a new scripts[] entry (discover-commands.sh / write-commands-cache.sh)
# with no version bump, so no existing install ever received them without a fresh install.
#
# This compares registry.json's working tree against the nearest released tag reachable from
# HEAD (the most recent vX.Y.Z tag, or itself if HEAD already is one) — not every historical
# commit, so several commits' worth of edits are free to land before the version bump that
# covers all of them, exactly once, before the next tag.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PREV_TAG=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)
}

@test "registry.json bumps an entry's version whenever its own fields change since the last release" {
  [ -n "$PREV_TAG" ] || skip "no released tag reachable from HEAD to diff against"

  local prev_json
  prev_json=$(git -C "$REPO_ROOT" show "$PREV_TAG:registry.json" 2>/dev/null) || skip "registry.json did not exist at $PREV_TAG"

  local cur_file="$REPO_ROOT/registry.json"
  local failures=""

  for section in agents skills; do
    while IFS= read -r name; do
      [ -n "$name" ] || continue

      local prev_entry_novers cur_entry_novers prev_version cur_version
      prev_entry_novers=$(jq -c --arg s "$section" --arg n "$name" '.[$s][$n] | del(.version)' <<< "$prev_json")
      cur_entry_novers=$(jq -c --arg s "$section" --arg n "$name" '.[$s][$n] | del(.version)' "$cur_file")

      [ "$prev_entry_novers" = "null" ] && continue   # new entry since $PREV_TAG — nothing to bump

      if [ "$prev_entry_novers" != "$cur_entry_novers" ]; then
        prev_version=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n].version // "unknown"' <<< "$prev_json")
        cur_version=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n].version // "unknown"' "$cur_file")
        if [ "$prev_version" = "$cur_version" ]; then
          failures="${failures}  $section.$name changed since $PREV_TAG but version stayed $cur_version\n"
        fi
      fi
    done < <(jq -r --arg s "$section" '.[$s] | keys[]' "$cur_file")
  done

  if [ -n "$failures" ]; then
    printf 'install.sh --update would silently skip these (unbumped despite a content change):\n%b' "$failures" >&2
    return 1
  fi
}
