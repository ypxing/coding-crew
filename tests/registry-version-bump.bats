#!/usr/bin/env bats

# install.sh --update (both the crew.lock tarball path and the legacy manifest path) decides
# whether to reinstall an agent/skill by comparing registry.json's version field alone — see
# run_update_from_lockfile / run_update in install.sh. If an entry's own effect (registry.json
# fields, or the actual files it ships) changes without its version also changing, every
# existing --update silently keeps the old files forever, with no error and no hint that
# anything was skipped.
#
# v1.29.0 shipped exactly this twice over: crew-afk and solve-issue each grew a new scripts[]
# entry (a registry.json field change) with no version bump, and the very next commit edited
# orchestrator/main.mjs — one of crew-afk's shipped *asset files* — with registry.json's fields
# left untouched, which a check of registry.json's own diff alone cannot see at all.
#
# This compares both against the nearest released tag reachable from HEAD (the most recent
# vX.Y.Z tag, or itself if HEAD already is one) — not every historical commit, so several
# commits' worth of edits are free to land before the version bump that covers all of them,
# exactly once, before the next tag:
#   1. registry.json's own entry fields (source-dir, assets, scripts, platform-files, deps, …)
#   2. the actual files that entry ships: its source-dir tree, its assets.source tree, each
#      scripts[] entry resolved at scripts/skill-utils/git-workflow/<name>, and each
#      platform-files[<platform>][] entry resolved under its source-dir

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PREV_TAG=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)
}

# _shipped_paths <section> <name> — every repo-relative path <section>.<name> actually ships,
# derived from the *current* registry.json (good enough to detect "something changed": a path
# added since $PREV_TAG diffs as newly-added, a path removed is simply not checked here but its
# removal already changed the scripts[]/assets JSON itself, which check 1 above already covers).
_shipped_paths() {
  local section="$1" name="$2" cur_file="$REPO_ROOT/registry.json"
  local source_dir assets_source
  source_dir=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n]["source-dir"] // empty' "$cur_file")
  assets_source=$(jq -r --arg s "$section" --arg n "$name" '
    .[$s][$n] as $e
    | ($e.assets.source // empty),
      (if ($e.install | type) == "object" then ($e.install.assets.source // empty) else empty end)
  ' "$cur_file" | grep -v '^$' | head -1)
  [ -n "$source_dir" ] && [ "$section" = "skills" ] && echo "skills/$source_dir"
  [ -n "$source_dir" ] && [ "$section" = "agents" ] && echo "agents/$source_dir"
  [ -n "$assets_source" ] && echo "$assets_source"
  if [ "$section" = "skills" ]; then
    while IFS= read -r script; do
      [ -n "$script" ] && echo "scripts/skill-utils/git-workflow/$script"
    done < <(jq -r --arg n "$name" '.skills[$n].scripts // [] | .[]' "$cur_file")
    while IFS= read -r pf; do
      [ -n "$pf" ] && [ -n "$source_dir" ] && echo "skills/$source_dir/$pf"
    done < <(jq -r --arg n "$name" '.skills[$n]["platform-files"] // {} | to_entries[] | .value[]' "$cur_file")
  fi
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

      local prev_entry_novers cur_entry_novers prev_version cur_version reason
      prev_entry_novers=$(jq -c --arg s "$section" --arg n "$name" '.[$s][$n] | del(.version)' <<< "$prev_json")
      cur_entry_novers=$(jq -c --arg s "$section" --arg n "$name" '.[$s][$n] | del(.version)' "$cur_file")

      [ "$prev_entry_novers" = "null" ] && continue   # new entry since $PREV_TAG — nothing to bump

      reason=""
      [ "$prev_entry_novers" != "$cur_entry_novers" ] && reason="registry.json fields"

      if [ -z "$reason" ]; then
        while IFS= read -r path; do
          [ -n "$path" ] || continue
          if ! git -C "$REPO_ROOT" diff --quiet "$PREV_TAG" -- "$path" 2>/dev/null; then
            reason="shipped file $path"
            break
          fi
        done < <(_shipped_paths "$section" "$name")
      fi

      if [ -n "$reason" ]; then
        prev_version=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n].version // "unknown"' <<< "$prev_json")
        cur_version=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n].version // "unknown"' "$cur_file")
        if [ "$prev_version" = "$cur_version" ]; then
          failures="${failures}  $section.$name changed ($reason) since $PREV_TAG but version stayed $cur_version\n"
        fi
      fi
    done < <(jq -r --arg s "$section" '.[$s] | keys[]' "$cur_file")
  done

  if [ -n "$failures" ]; then
    printf 'install.sh --update would silently skip these (unbumped despite a content change):\n%b' "$failures" >&2
    return 1
  fi
}
