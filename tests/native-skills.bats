#!/usr/bin/env bats

# CLAUDE.md's native rule: a skill uses another skill by name, and reaches code shared between skills
# only through the library in its own scripts/ directory (<skill-dir>/scripts/<lib>/: committed as a link into
# lib/, installed as a real directory), so an installed skill can be read and run on its own. And every SKILL.md's frontmatter follows the
# Agent Skills spec, plus argument-hint and disable-model-invocation, which Claude Code reads.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  T="$(mktemp -d)"
}
teardown() { rm -rf "$T"; }

# scan_skill_paths <root> — prints each line under <root>/skills that reaches into another skill's
# directory or a library outside <skill-dir>/scripts/<lib>/, as `<path relative to root>:<n>: <line>`;
# exits 1 when any does. A skill's scripts/<lib> is a link into lib/, not skill prose: `find -type f` does
# not follow it, so it is not scanned.
scan_skill_paths() {
  local root="$1" skills libs f hits=""
  skills=$(cd "$root/skills" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||' | paste -sd'|' -)
  libs=$(cd "$REPO_ROOT/lib" && find . -mindepth 1 -maxdepth 1 -type d | sed 's|^\./||' | paste -sd'|' -)
  local into_skill="(\.\./|\.coding-crew/)($skills)/|\\\$\{?SELF[A-Z_]*\}?/\.\./\.\./"
  local lib_token="[^[:space:]\"'\`(=]*($libs)/[^[:space:]\"'\`)]*"
  local lib_ok="(^|/)scripts/($libs)/|\\\$\{?SELF[A-Z_]*\}?/($libs)/"
  while IFS= read -r f; do
    # .coding-crew/solve-feature/ is solve-feature's run directory in the consuming repo, not the skill.
    hits+=$(sed 's#\.coding-crew/solve-feature/#<run-dir>/#g' "$root/$f" | grep -nE "$into_skill" | sed "s|^|$f:|")$'\n'
    hits+=$(grep -noE "$lib_token" "$root/$f" | while IFS=: read -r n tok; do
      [[ "$tok" =~ $lib_ok ]] || echo "$f:$n: $tok"
    done)$'\n'
  done < <(cd "$root" && find skills -type f ! -name CHANGELOG.md | LC_ALL=C sort)
  hits=$(printf '%s' "$hits" | sed '/^$/d')
  [ -z "$hits" ] || { printf '%s\n' "$hits"; return 1; }
}

@test "no skill file reaches into another skill, or a library outside its own scripts/" {
  run scan_skill_paths "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the path scan fails on a planted path into another skill or a library, naming the file" {
  cp -R "$REPO_ROOT/skills" "$T/skills"
  run scan_skill_paths "$T"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  local f planted
  for f in skills/tdd/references/mocking.md skills/solve-issue/SKILL.md; do
    cp "$T/$f" "$T/$f.orig"
    for planted in 'bash "<skill-dir>/../solve-issue/scripts/preflight.sh"' \
                   'node "$SELF/../../tracker/cli.mjs" config' \
                   'bash .coding-crew/dep-install/scripts/run.sh' \
                   'node "$(git rev-parse --show-toplevel)/.coding-crew/lib/tracker/cli.mjs" fetch 1' \
                   'bash lib/checks/run-checks.sh'; do
      echo "$planted" >> "$T/$f"
      run scan_skill_paths "$T"
      [ "$status" -eq 1 ] || { echo "not caught: $planted"; return 1; }
      [[ "$output" == *"$f:"* ]] || { echo "$output"; return 1; }
      cp "$T/$f.orig" "$T/$f"
    done
  done
}

# frontmatter <SKILL.md> — one `key<TAB>value` line per top-level key; a folded value's lines joined by spaces.
frontmatter() {
  awk 'NR == 1 { next } /^---/ { exit }
       /^[A-Za-z_-]+:/ { if (k != "") print k "\t" v; k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); if (v == ">" || v == "|") v = ""; next }
       { sub(/^[[:space:]]+/, ""); v = (v == "" ? $0 : v " " $0) }
       END { if (k != "") print k "\t" v }' "$1"
}

@test "every SKILL.md's frontmatter follows the Agent Skills spec" {
  local f dir key value fails=""
  for f in "$REPO_ROOT"/skills/*/SKILL.md; do
    dir=$(basename "$(dirname "$f")")
    [ "$(wc -l < "$f")" -lt 500 ] || fails+="$dir: SKILL.md has 500 lines or more"$'\n'
    while IFS=$'\t' read -r key value; do
      case "$key" in
        name) [ "$value" = "$dir" ] || fails+="$dir: name '$value' is not the directory's"$'\n' ;;
        description)
          [ "${#value}" -le 1024 ] || fails+="$dir: description is ${#value} characters"$'\n'
          [[ "$value" == *"Use when"* ]] || fails+="$dir: description does not say when to use it"$'\n' ;;
        allowed-tools) [[ "$value" != *,* ]] || fails+="$dir: allowed-tools is not space-delimited"$'\n' ;;
        license | compatibility | metadata | argument-hint | disable-model-invocation) ;;
        *) fails+="$dir: frontmatter key '$key' is not in the spec"$'\n' ;;
      esac
    done < <(frontmatter "$f")
  done
  [ -z "$fails" ] || { printf '%s' "$fails"; return 1; }
}

# Codex ignores disable-model-invocation and reads agents/openai.yaml's policy instead.
@test "add-tests and upgrade-deps run only when a person invokes them, on every platform" {
  local dir fails=""
  for dir in add-tests upgrade-deps; do
    frontmatter "$REPO_ROOT/skills/$dir/SKILL.md" | grep -qx $'disable-model-invocation\ttrue' \
      || fails+="$dir: no disable-model-invocation: true"$'\n'
    grep -qE '^[[:space:]]+allow_implicit_invocation: false$' "$REPO_ROOT/skills/$dir/agents/openai.yaml" 2>/dev/null \
      || fails+="$dir: agents/openai.yaml does not set allow_implicit_invocation: false"$'\n'
  done
  [ -z "$fails" ] || { printf '%s' "$fails"; return 1; }
}
