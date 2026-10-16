#!/usr/bin/env bats

# registry.json's deps are what install.sh installs alongside a skill (recursively), so they must
# match what the skill's text tells the agent to invoke: a skill it names but cannot reach is
# missing when that skill is installed alone, and a dep it never names is installed for nothing.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  T="$(mktemp -d)"
}
teardown() { rm -rf "$T"; }

# Mentions that point a person or a reader at another skill without invoking it, as
# `<skill> <name>  # reason`. A skill is never required to install what it only points at.
ALLOWLIST='
add-tests crew-grill            # an analogy: crew-grill hands its design over the same way
add-tests tdd                   # cites tdd'"'"'s rule the coder follows; the coder runs solve-issue
crew-afk crew-grill             # tells the person to plan the feature first
crew-afk crew-brainstorm        # tells the person to plan the feature first
crew-afk to-issues              # tells the person to plan the feature first
setup-coding-crew solve-feature # what setup prepares the repo for, and its workflow file
setup-coding-crew solve-issue   # says which earlier run discovered the dev commands file
to-issues solve-issue           # human-issue: where a person finds the tracker CLI (scripts/tracker/)
to-issues add-tests             # a caller: names the findings file add-tests hands over
to-issues crew-grill            # a caller: hands over its design summary
to-issues crew-brainstorm       # a caller: hands over its design summary
to-prd crew-grill               # a caller: its summary holds settled decisions
to-prd crew-brainstorm          # a caller: its summary holds settled decisions
to-prd to-issues                # a caller: it hands over the slug
upgrade-deps solve-issue        # human-issue: where a person finds the tracker CLI (scripts/tracker/)
'

# named_skills <names-regex> — the registry names stdin names as a skill, one per line: a whole
# word that is backticked (`x`), written as /x, or written as "the x skill" (also inside a longer
# backticked prompt). A path such as skills/x/ or workflows/x.yml is not a name.
named_skills() {
  local alt="$1"
  grep -oE "\`($alt)\`|(^|[^A-Za-z0-9_.~/>-])/($alt)([^A-Za-z0-9_-]|\$)|[Tt]he ($alt) skill([^A-Za-z0-9_-]|\$)" \
    | grep -oE "$alt" | LC_ALL=C sort -u
}

# reach <registry> <skill> — the skill and every skill its deps reach, one per line.
reach() {
  jq -r --arg s "$2" '
    .skills as $all
    | def walk($seen): ($seen + [$seen[] | ($all[.].deps // [])[]] | unique) as $next
        | if $next == $seen then $seen else walk($next) end;
      walk([$s])[]' "$1"
}

# scan_skill_deps <root> — checks every registry skill under <root> (its registry.json and skills/; a
# committed SKILL.md is the rendered body, and scripts/<lib>/ copies are lib/'s, not the skill's) and prints one line per failure, naming the skill and the name;
# exits 1 when any fails.
scan_skill_deps() {
  local root="$1" reg="$1/registry.json" names alt s dir doc reachable named n fails=""
  names=$(jq -r '.skills | keys[]' "$reg")
  alt=$(printf '%s\n' "$names" | paste -sd'|' -)
  for s in $names; do
    dir="$root/skills/$(jq -r --arg s "$s" '.skills[$s]["source-dir"] // $s' "$reg")"
    doc=$(cat "$dir/SKILL.md")
    [ -d "$dir/references" ] && doc+=$'\n'$(cat "$dir"/references/*.md)
    reachable=$(reach "$reg" "$s")
    for n in $(printf '%s\n' "$doc" | named_skills "$alt"); do
      grep -qxF "$n" <<<"$reachable" && continue
      grep -qE "^$s $n( |\$)" <<<"$ALLOWLIST" && continue
      fails+="$s: names $n, which its deps do not reach"$'\n'
    done
    named=$( { printf '%s\n' "$doc"; [ -d "$dir/scripts" ] && find "$dir/scripts" -type f | grep -vE "^$dir/scripts/($(jq -r --arg s "$s" '.skills[$s].libs // [] | join("|")' "$reg"))/" | while IFS= read -r f; do cat "$f"; done; } | named_skills "$alt")
    for n in $(jq -r --arg s "$s" '.skills[$s].deps // [] | .[]' "$reg"); do
      grep -qxF "$n" <<<"$named" || fails+="$s: dep $n is not named in its SKILL.md, references/ or scripts/"$'\n'
    done
  done
  [ -z "$fails" ] || { printf '%s' "$fails"; return 1; }
}

@test "every skill a skill names is reachable through its deps, and every dep is named" {
  run scan_skill_deps "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the matcher reads backticks, /x and 'the x skill', and not paths or longer words" {
  local alt='solve-issue|write-pr'
  [ "$(printf '%s\n' 'run `write-pr` now' | named_skills "$alt")" = write-pr ]
  [ "$(printf '%s\n' 'then /write-pr.' | named_skills "$alt")" = write-pr ]
  [ "$(printf '%s\n' '`Use the solve-issue skill on <ref>`' | named_skills "$alt")" = solve-issue ]
  [ -z "$(printf '%s\n' 'skills/write-pr/SKILL.md .github/workflows/write-pr.yml' | named_skills "$alt")" ]
  [ -z "$(printf '%s\n' '`write-prs` /write-pr-x the write-pr-x skill' | named_skills "$alt")" ]
}

@test "the deps scan fails on a planted undeclared skill and a planted unnamed dep, naming both" {
  cp -R "$REPO_ROOT/skills" "$T/skills"
  cp "$REPO_ROOT/registry.json" "$T/registry.json"
  run scan_skill_deps "$T"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  local f="$T/skills/tdd/SKILL.md" planted
  cp "$f" "$f.orig"
  for planted in 'Then invoke the write-pr skill.' 'Then run `write-pr`.' 'Then run /write-pr.'; do
    echo "$planted" >> "$f"
    run scan_skill_deps "$T"
    [ "$status" -eq 1 ] || { echo "not caught: $planted"; return 1; }
    [[ "$output" == *"tdd: names write-pr"* ]] || { echo "$output"; return 1; }
    cp "$f.orig" "$f"
  done

  jq '.skills.tdd.deps = ["crew-review"]' "$REPO_ROOT/registry.json" > "$T/registry.json"
  run scan_skill_deps "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tdd: dep crew-review is not named"* ]] || { echo "$output"; return 1; }
}
