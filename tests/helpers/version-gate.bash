# Shared by tests/registry-version-bump.bats.
# D4: an entry the branch changed must carry a version strictly above origin/main's.

# _shipped_paths <registry.json> <section> <name> — repo-relative paths the entry ships.
_shipped_paths() {
  local cur_file="$1" section="$2" name="$3"
  local source_dir assets_source
  source_dir=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n]["source-dir"] // empty' "$cur_file")
  assets_source=$(jq -r --arg s "$section" --arg n "$name" '
    .[$s][$n] as $e
    | ($e.assets.source // empty),
      (($e["more-assets"] // [])[] | .source)
  ' "$cur_file" | grep -v '^$')
  [ -n "$source_dir" ] && [ "$section" = "skills" ] && echo "skills/$source_dir"
  [ -n "$source_dir" ] && [ "$section" = "agents" ] && echo "agents/$source_dir"
  [ -n "$assets_source" ] && echo "$assets_source"
  if [ "$section" = "skills" ]; then
    while IFS= read -r script; do
      [ -n "$script" ] && echo "scripts/skill-utils/git-workflow/$script"
    done < <(jq -r --arg n "$name" '.skills[$n].scripts // [] | .[]' "$cur_file")
  fi
  return 0
}

# version_gate_failures <base.json> <branch.json> <main.json> <changed-paths-file>
# base = registry at the merge-base with main. Prints one line per violation.
version_gate_failures() {
  local base="$1" branch="$2" main="$3" changed="$4" section name
  for section in agents skills; do
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      local main_v branch_v reason="" b_novers c_novers top shipped
      main_v=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n].version // empty' "$main")
      [ -n "$main_v" ] || continue   # absent on main
      b_novers=$(jq -c --arg s "$section" --arg n "$name" '.[$s][$n] | del(.version)' "$base")
      c_novers=$(jq -c --arg s "$section" --arg n "$name" '.[$s][$n] | del(.version)' "$branch")
      [ "$b_novers" != "$c_novers" ] && reason="registry.json fields"
      if [ -z "$reason" ]; then
        # Captured first: breaking out of a `< <(...)` loop leaves the producer writing to a closed pipe.
        shipped=$(_shipped_paths "$branch" "$section" "$name")
        while IFS= read -r path; do
          [ -n "$path" ] || continue
          if grep -qxF -e "$path" "$changed" || awk -v p="$path/" 'index($0, p) == 1 { f = 1; exit } END { exit !f }' "$changed"; then
            reason="shipped file $path"; break
          fi
        done <<< "$shipped"
      fi
      [ -n "$reason" ] || continue
      branch_v=$(jq -r --arg s "$section" --arg n "$name" '.[$s][$n].version // "0"' "$branch")
      top=$(printf '%s\n%s\n' "$main_v" "$branch_v" | sort -V | tail -1)
      if [ "$branch_v" = "$main_v" ] || [ "$top" != "$branch_v" ]; then
        echo "  $section.$name changed ($reason) but branch version $branch_v is not above origin/main's $main_v"
      fi
    done < <(jq -r --arg s "$section" '.[$s] // {} | keys[]' "$branch")
  done
}
