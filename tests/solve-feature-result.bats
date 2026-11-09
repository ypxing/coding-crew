#!/usr/bin/env bats

# solve-feature.sh's result.json: every ending outcome() writes also renders .coding-crew/solve-feature/result.json,
# checked against skills/solve-feature/result.schema.json. Setup and the stubs: helpers/solve-feature.bash.

load helpers/solve-feature

D=.coding-crew/solve-feature
SCHEMA="$REPO_ROOT/skills/solve-feature/result.schema.json"

# schema_errors <json file> — one line per place the file breaks the schema's type, enum, required, properties and
# items entries; none when it validates.
schema_errors() {
  jq -r --slurpfile s "$SCHEMA" '
    def types: if type == "number" and . == floor then ["number", "integer"] else [type] end;
    def errs($s; $p):
      . as $v
      | ( if $s.type == null then empty
          else ($s.type | if type == "array" then . else [.] end) as $ts
            | if any($v | types[]; . as $x | any($ts[]; . == $x)) then empty else "\($p): \($v | type), want \($ts | join("|"))" end
          end ),
        ( if $s.enum == null or any($s.enum[]; . == $v) then empty else "\($p): \($v) not in \($s.enum)" end ),
        ( if ($v | type) == "object" then
            ( ($s.required // [])[] | select(. as $k | $v | has($k) | not) | "\($p): missing \(.)" ),
            ( ($s.properties // {}) | to_entries[] | .key as $k | .value as $ps | select($v | has($k)) | $v[$k] | errs($ps; "\($p).\($k)") )
          else empty end ),
        ( if ($v | type) == "array" and $s.items != null then
            $v | to_entries[] | .key as $i | .value | errs($s.items; "\($p)[\($i)]")
          else empty end );
    errs($s[0]; "$")' "$1"
}

# result_ok — result.json validates against the schema and carries the outcome file's line.
result_ok() {
  [ -f "$D/result.json" ] || { echo "no result.json"; return 1; }
  local e; e=$(schema_errors "$D/result.json")
  [ -z "$e" ] || { echo "$e"; cat "$D/result.json"; return 1; }
  [ "$(jq -r .outcome "$D/result.json")" = "$(head -n1 "$D/outcome")" ] || { cat "$D/result.json"; return 1; }
}
r() { jq -c "$1" "$D/result.json"; }

fix_ready() {
  loop
  [ "$LAST_PR" = 10 ]
  local one='{"spec":"met","gaps":[],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  report "${1:-$one}"
  echo fixed > fixed.txt
}

@test "a ready run leaves result.json: the outcome, the branch, HEAD, the PR, each issue's commits and checks, and its one round" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  local checked; checked=$(cat "$D/review.base")
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "ready pr=10" ]
  result_ok
  [ "$(r '[.outcome, .branch, .head, .pr]')" = "[\"ready pr=10\",\"feature/feat\",\"$(git rev-parse HEAD)\",10]" ]
  [ "$(r 'has("pr_title") or has("pr_body")')" = false ]
  [ "$(r '[.issues[] | [.ref, .title, .status, .commits, .red]]')" = '[["3-three","Three","done",["[3] work"],[]],["2-two","Two","done",["[2] work"],[]]]' ]
  [ "$(r '.issues[1].checks')" = "{\"commit\":\"$(cat "$D/2.checks.head")\",\"results\":[{\"key\":\"test\",\"result\":\"pass\"}]}" ]
  [ "$(r '.rounds | length')" = 1 ]
  [ "$(r '.rounds[0] | [.spec, .gaps, (.findings | length), .unfixed, .fixer_changed_code, .checks, .checks_commit, .re_reviewed]')" = \
    "[\"met\",[],1,[],true,[{\"key\":\"test\",\"result\":\"pass\"}],\"$checked\",false]" ]
}

@test "a needs-attention run and a fix stop each leave a result.json; the stopped round has null where fix stopped first" {
  fix_ready '{"spec":"unmet","gaps":["no logout"],"findings":[]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  local c1; c1=$(cat "$D/review.base")
  run bash "$SCRIPT" describe feat 10
  [ "$output" = "needs-attention pr=10" ]
  result_ok
  [ "$(r '.rounds[0].gaps')" = '["no logout"]' ]

  # A fix stop: its report is never moved, so it is the last round, with nothing fix computed.
  rereview
  echo again > fixed.txt
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  result_ok
  [[ "$(r .outcome)" == '"stopped: review fix failed: run-checks.sh exit 1'* ]]
  [ "$(r '[.rounds[] | [.re_reviewed, .fixer_changed_code, .checks, .checks_commit]]')" = '[[true,true,[{"key":"test","result":"pass"}],"'"$c1"'"],[false,null,null,null]]' ]
}

@test "a land stop and nothing landed leave a result.json; an issue this run did not land has checks null" {
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat
  coder 2
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  result_ok
  [[ "$(r .outcome)" == '"stopped: 2 checks failed: '* ]]
  [ "$(r '[.issues[] | [.ref, .status, .checks]]')" = '[["3-three","not done",null],["2-two","not done",null]]' ]
  [ "$(r .rounds)" = '[]' ]

  issues '[{"number":1,"title":"PRD: Feat","state":"OPEN","labels":[],"root":true}]'
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  result_ok
  [[ "$(r .outcome)" == *"nothing landed"* ]]
  [ "$(r 'has("pr")')" = false ]
}

@test "a failed render prints to stderr and leaves the exit code and the outcome line as they would be without it" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  echo 'not json' > "$D/pr-10.r1.review.json"
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "ready pr=10" ]
  [[ "$output" == *"solve-feature: writing $WORK/$D/result.json failed (see above)"* ]]
  [ "$(cat "$D/outcome")" = "ready pr=10" ]
  [ ! -e "$D/result.json" ]
}

@test "start deletes an earlier run's result.json, round files and checks heads; sync deletes result.json with outcome; next deletes a re-dispatched issue's red file" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  run bash "$SCRIPT" describe feat 10
  [ -f "$D/result.json" ] && [ -f "$D/pr-10.r1.review.json" ] && [ -f "$D/2.checks.head" ]
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  [ ! -e "$D/result.json" ]
  [ -z "$(ls "$D" | grep -E '^pr-.*\.r[0-9]+\.|\.checks\.head$')" ]

  echo 'stopped: x' > "$D/outcome" && echo '{}' > "$D/result.json"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ]
  [ ! -e "$D/outcome" ] && [ ! -e "$D/result.json" ]

  issues '[{"number":2,"title":"Two","state":"OPEN","labels":[{"name":"ready-for-agent"}]}]'
  echo 'a.bats: old — boom' > "$D/2.red.md"
  echo 'x.bats: other — boom' > "$D/3.red.md"
  run bash "$SCRIPT" next feat
  [ "$output" = 2 ]
  [ ! -e "$D/2.red.md" ] && [ -f "$D/3.red.md" ]
}

@test "with round 1's report moved away, a round-2 reviewer that writes no report still makes fix stop with no review report" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ ! -e "$D/pr-10.review.json" ] && [ -f "$D/pr-10.r1.review.json" ]
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"review fix failed: no review report at $WORK/$D/pr-10.review.json"* ]]
}

@test "two review rounds give two rounds, each with its own review, unfixed lines and checks, and criteria joined to the red lines by exact test string" {
  fix_ready
  printf '%s\n' 'tests/a.bats: logs out — expected 200, got 404' 'tests/a.bats: logs out twice — expected 1' > "$D/2.red.md"
  echo 'tests/b.bats: three — boom' > "$D/3.red.md"
  report '{"spec":"unmet","gaps":["g1"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}],
    "criteria":[{"issue":"2-two","text":"logs out","met":true,"tests":["tests/a.bats: logs out","tests/a.bats: logs"]}]}'
  echo '- a:1 needs a person' > "$D/pr-10.unfixed.md"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [[ "${lines[${#lines[@]}-1]}" == *"review-again=yes" ]]
  local c1; c1=$(cat "$D/review.base")
  report '{"spec":"met","gaps":[],"findings":[],"criteria":[{"issue":"3-three","text":"three","met":true,"tests":["tests/b.bats: three"]}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" describe feat 10
  result_ok
  [ "$(r '[.rounds[] | [.spec, .gaps, (.findings | length), .unfixed, .re_reviewed, .fixer_changed_code]]')" = \
    '[["unmet",["g1"],1,["- a:1 needs a person"],true,true],["met",[],0,[],false,false]]' ]
  [ "$(r '.rounds[0].checks_commit')" = "\"$c1\"" ]
  [ "$(r '.rounds[1].checks_commit')" = "\"$(git rev-parse HEAD)\"" ]
  [ "$(r '.rounds[0].criteria')" = '[{"issue":"2-two","text":"logs out","met":true,"tests":[{"test":"tests/a.bats: logs out","red":"tests/a.bats: logs out — expected 200, got 404"},{"test":"tests/a.bats: logs","red":null}]}]' ]
  [ "$(r '.rounds[0].unmatched_red')" = '["tests/b.bats: three — boom","tests/a.bats: logs out twice — expected 1"]' ]
  [ "$(r '.rounds[1].unmatched_red')" = '["tests/a.bats: logs out — expected 200, got 404","tests/a.bats: logs out twice — expected 1"]' ]
  [ "$(r '[.issues[] | .red | length]')" = '[1,2]' ]
  # The writer's prompt still names the live checks log.
  [ -f "$D/pr-10.checks.log" ]
}

@test "issues are this run's spec sections only, with first-parent [<slug>] commits past the default branch" {
  # Another feature's files in the shared directory are never listed.
  echo 99 > "$D/99.ref" && echo '# Other' > "$D/99.issue.md" && echo 'x: y — z' > "$D/99.red.md"
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat
  coder 2
  echo more >> work-2.txt && git commit -qam "[2][WIP] more"
  # A [2] commit the default branch brings in sits behind the merge's second parent.
  git checkout -q -b side origin/main && echo m > m.txt && git add m.txt && git commit -qm "[2] on main" && git push -q origin side:main
  git checkout -q feature/feat && git fetch -q origin && git merge -q --no-edit origin/main
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  result_ok
  [ "$(r '[.issues[].ref]')" = '["3-three","2-two"]' ]
  [ "$(r '.issues[1].commits')" = '["[2] work","[2][WIP] more"]' ]
  [ "$(r '.issues[0].commits')" = '[]' ]
}

@test "with publish false result.json has pr_title and pr_body from the local body once it exists, and no pr" {
  mkdir -p "$HOME/.coding-crew" && echo '{"solveFeature":{"publish":false}}' > "$HOME/.coding-crew/config.json"
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat
  coder 2
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  result_ok
  [ "$(r '[has("pr_title"), has("pr_body"), has("pr")]')" = '[false,false,false]' ]
  run bash "$SCRIPT" next feat
  coder 2
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  printf '# Feat title\n\nline one\nline two\n' > "$D/local-pr-feature_feat.md"
  run bash "$SCRIPT" next feat
  coder 3
  CHECKS_RC=1 run bash "$SCRIPT" land feat 3 feature/feat
  result_ok
  [ "$(r '[.pr_title, .pr_body, has("pr")]')" = '["Feat title","line one\nline two\n",false]' ]
}
