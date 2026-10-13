#!/usr/bin/env bats

# review-pr.sh — one read-only agent reviews a checked-out PR against the spec in its body, posts one
# COMMENT review and flips a draft to ready when the spec is met with no CRITICAL/HIGH finding; agent.sh
# beside it owns the coding-agent axis (argv, coder prompt, model) for review-pr and solve-feature.
#
# A temp repo whose HEAD is the stubbed PR's head; `gh`, `claude`, `copilot`, `pi`, `codex` and `timeout`
# are stubs on PATH logging their argv into $STATE (the prompt — `-p`'s value, pi's last argument, codex's
# stdin — as `<prompt>` in the argv and whole in agent.<k>.prompt). The agent stub writes the report its
# prompt names from $REPORT_JSON, or none; it can also dirty or commit the tree.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SCRIPTS="$REPO_ROOT/skills/review-pr/scripts"
SCRIPT="$SCRIPTS/review-pr.sh"

setup() {
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  export STATE="$TEMP_DIR/state" HOME="$TEMP_DIR/home"
  mkdir -p "$STATE" "$HOME"
  unset SOLVE_FEATURE_AGENT REPORT_JSON AGENT_DIRTY AGENT_COMMIT GH_POST_FAIL

  WORK="$TEMP_DIR/work"
  git init -q -b main "$WORK"
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name test
  mkdir -p "$WORK/.coding-crew"
  echo '{"tracker":{"kind":"github"}}' > "$WORK/.coding-crew/config.json"
  printf 'a\nb\nc\n' > "$WORK/lib.sh"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
  git -C "$WORK" checkout -q -b feature/x
  HEAD_OID=$(git -C "$WORK" rev-parse HEAD)

  STUB="$TEMP_DIR/stub"
  mkdir -p "$STUB"
  write_stubs
  export PATH="$STUB:$PATH"

  pr_view "$HEAD_OID" true "<!-- solve-feature:begin -->\nintro\n<details><summary>Spec</summary>\n\n# Spec body\n\n</details>\nafter"
  printf 'diff --git a/lib.sh b/lib.sh\n--- a/lib.sh\n+++ b/lib.sh\n@@ -1,3 +1,4 @@\n a\n+new\n b\n c\n' > "$STATE/pr.diff"
  echo '[]' > "$STATE/reviews.json"
  echo '[]' > "$STATE/comments.json"
  cd "$WORK"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# pr_view <headRefOid> <isDraft> <body with \n escapes>
pr_view() {
  jq -n --arg oid "$1" --argjson draft "$2" --arg body "$(printf "$3")" \
    '{body: $body, headRefOid: $oid, isDraft: $draft, url: "https://github.com/o/r/pull/9"}' > "$STATE/pr.json"
}

write_stubs() {
  cat > "$STUB/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$STATE/timeout.arg"
shift
exec "$@"
EOF
  # Every agent: argv one per line in agent.<k>, the prompt replaced by `<prompt>`; the report path is the
  # prompt's `Write your report to <path>`. The prompt is `-p`'s value (claude, copilot), the last argument
  # (pi) or stdin (codex); agent.<k>.stdin is `/dev/null` or what stdin carried.
  for a in claude copilot pi codex; do
    cat > "$STUB/$a" <<EOF
#!/usr/bin/env bash
k=\$(( \$(ls "\$STATE" | grep -c '^agent\.[0-9]*\$') + 1 ))
if [ /dev/stdin -ef /dev/null ]; then echo /dev/null > "\$STATE/agent.\$k.stdin"; else cat > "\$STATE/agent.\$k.stdin"; fi
case "$a" in
  codex) prompt=\$(cat "\$STATE/agent.\$k.stdin"); printf '%s\\n' "$a" "\$@" > "\$STATE/agent.\$k" ;;
  pi) prompt="\${@: -1}"; printf '%s\\n' "$a" "\${@:1:\$#-1}" "<prompt>" > "\$STATE/agent.\$k" ;;
  *) prompt="\$2"; printf '%s\\n' "$a" "\$1" "<prompt>" "\${@:3}" > "\$STATE/agent.\$k" ;;
esac
printf '%s\\n' "\$prompt" > "\$STATE/agent.\$k.prompt"
report=\$(sed -n 's/^Write your report to \\(.*\\) as your last action.*/\\1/p' "\$STATE/agent.\$k.prompt")
[ -z "\${REPORT_JSON:-}" ] || printf '%s\\n' "\$REPORT_JSON" > "\$report"
[ -z "\${AGENT_DIRTY:-}" ] || echo dirt > reviewer-dirt.txt
[ -z "\${AGENT_COMMIT:-}" ] || git commit -q --allow-empty -m "reviewer wrote"
echo '{"type":"result","result":"reviewed"}'
EOF
  done
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/gh.log"
case "$1 $2" in
  "pr view") cat "$STATE/pr.json" ;;
  "pr diff") cat "$STATE/pr.diff" ;;
  "pr ready") ;;
  "api repos/{owner}/{repo}/pulls/9/reviews")
    if [[ "$*" == *"--method POST"* ]]; then
      [ -z "${GH_POST_FAIL:-}" ] || { echo "gh: HTTP 422 Unprocessable" >&2; exit 1; }
      for ((i = 1; i <= $#; i++)); do [ "${!i}" = --input ] && { j=$((i + 1)); cp "${!j}" "$STATE/payload.json"; }; done
      echo '{"id": 1}'
    else cat "$STATE/reviews.json"; fi ;;
  "api repos/{owner}/{repo}/pulls/9/comments") cat "$STATE/comments.json" ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUB"/*
}

agent_call() { cat "$STATE/agent.$1"; }
agent_prompt() { cat "$STATE/agent.$1.prompt"; }
agent_calls() { ls "$STATE" | grep -c '^agent\.[0-9]*$' || true; }
# The value after flag $2 in agent call $1.
agent_flag() { agent_call "$1" | grep -A1 -x -- "$2" | tail -1; }
marker_of() { printf 'crew-finding:%s' "$(printf '%s' "$1" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1; } | cut -c1-12)"; }

# --- agent.sh on its own -----------------------------------------------------------------

@test "agent_cmd: claude coder argv, copilot coder argv without a model, unknown agent returns 1" {
  run bash -c '. "$1"; agent_cmd coder claude sonnet 5 "/solve-issue 2" && printf "%s\n" "${AGENT_ARGV[@]}"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' claude -p "/solve-issue 2" --output-format json --max-budget-usd 5 --model sonnet --permission-mode bypassPermissions)" ]
  run bash -c '. "$1"; agent_cmd coder copilot "" 5 x && printf "%s\n" "${AGENT_ARGV[@]}"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' copilot -p x --allow-all-tools --no-color --output-format json)" ]
  run bash -c '. "$1"; agent_cmd coder other "" 5 x' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  run bash -c '. "$1"; agent_cmd tester claude "" 5 x' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 1 ]
}

@test "agent_cmd: the reviewer arms add claude's read-only tools and settings, copilot's --deny-tool write" {
  run bash -c '. "$1"; agent_cmd reviewer claude "" 4 p && printf "%s\n" "${AGENT_ARGV[@]}"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' claude -p p --output-format json --max-budget-usd 4 --model opus --permission-mode bypassPermissions --tools Bash Read ToolSearch --settings '{"disableClaudeAiConnectors":true,"disableBundledSkills":true}')" ]
  run bash -c '. "$1"; agent_cmd reviewer copilot gpt 4 p && printf "%s\n" "${AGENT_ARGV[@]}"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' copilot -p p --allow-all-tools --no-color --output-format json --model gpt --deny-tool write)" ]
}

@test "agent_coder_prompt: claude's skill invocation, copilot's sentence naming the skill" {
  run bash -c '. "$1"; agent_coder_prompt claude 2' _ "$SCRIPTS/agent.sh"
  [ "$output" = "/solve-issue 2" ]
  run bash -c '. "$1"; agent_coder_prompt copilot .scratch/f/issues/open/01-a.md' _ "$SCRIPTS/agent.sh"
  [ "$output" = "Use the solve-issue skill on .scratch/f/issues/open/01-a.md." ]
  run bash -c '. "$1"; agent_coder_prompt other 2' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 1 ]
}

@test "agent_model: the default without a config, afk.models.<agent>.<role> with one" {
  run bash -c '. "$1"; agent_model claude reviewer opus' _ "$SCRIPTS/agent.sh"
  [ "$output" = opus ]
  echo '{"afk":{"models":{"claude":{"reviewer":"haiku"}}}}' > .coding-crew/config.json
  run bash -c '. "$1"; agent_model claude reviewer opus' _ "$SCRIPTS/agent.sh"
  [ "$output" = haiku ]
  run bash -c '. "$1"; agent_model claude coder sonnet' _ "$SCRIPTS/agent.sh"
  [ "$output" = sonnet ]
  run bash -c '. "$1"; agent_model copilot reviewer ""' _ "$SCRIPTS/agent.sh"
  [ "$output" = "" ]
}

@test "agent_known: 0 for claude, copilot, pi and codex, 1 for anything else" {
  local a
  for a in claude copilot pi codex; do
    run bash -c '. "$1"; agent_known "$2"' _ "$SCRIPTS/agent.sh" "$a"
    [ "$status" -eq 0 ] || { echo "$a: $status"; return 1; }
  done
  run bash -c '. "$1"; agent_known other' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 1 ]
  run bash -c '. "$1"; agent_known ""' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 1 ]
}

@test "agent_cmd: pi coder and reviewer argv, --model only when given, stdin /dev/null, the budget ignored" {
  run bash -c '. "$1"; agent_cmd coder pi "" 5 "Use the solve-issue skill on 2." && printf "%s\n" "${AGENT_ARGV[@]}" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' pi -p --mode json --tools read,bash,edit,write "Use the solve-issue skill on 2." /dev/null)" ]
  run bash -c '. "$1"; agent_cmd reviewer pi m1 4 p && printf "%s\n" "${AGENT_ARGV[@]}" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' pi -p --mode json --model m1 --tools read,bash p /dev/null)" ]
  run bash -c '. "$1"; agent_cmd coder claude sonnet 5 x && printf "%s\n" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$output" = /dev/null ]
  run bash -c '. "$1"; agent_cmd coder copilot "" 5 x && printf "%s\n" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$output" = /dev/null ]
}

@test "agent_cmd: codex coder argv with the git dir as a writable root (the main repo's in a linked worktree, plus the main checkout for the local tracker's close) and the prompt in .solve-feature/[<tag>.]coder.codex-prompt.md on stdin" {
  mkdir .solve-feature && echo '*' >.solve-feature/.gitignore
  run bash -c '. "$1"; agent_cmd coder codex "" 5 "Use the solve-issue skill on 2." && printf "%s\n" "${AGENT_ARGV[@]}" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' codex exec --cd "$WORK" --sandbox workspace-write -c sandbox_workspace_write.network_access=true -c "sandbox_workspace_write.writable_roots=[\"$WORK/.git\"]" --json - "$WORK/.solve-feature/coder.codex-prompt.md")" ]
  [ "$(cat "$WORK/.solve-feature/coder.codex-prompt.md")" = "Use the solve-issue skill on 2." ]
  run bash -c '. "$1"; agent_cmd coder codex gpt-5 5 x 2 && printf "%s\n" "${AGENT_ARGV[@]}" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$output" = "$(printf '%s\n' codex exec --cd "$WORK" --sandbox workspace-write -c sandbox_workspace_write.network_access=true -c "sandbox_workspace_write.writable_roots=[\"$WORK/.git\"]" --json --model gpt-5 - "$WORK/.solve-feature/2.coder.codex-prompt.md")" ]
  [ "$(cat "$WORK/.solve-feature/2.coder.codex-prompt.md")" = x ]

  git worktree add -q "$TEMP_DIR/wt" -b wt >/dev/null
  cd "$TEMP_DIR/wt"
  mkdir .solve-feature
  run bash -c '. "$1"; agent_cmd coder codex "" 5 x && printf "%s\n" "${AGENT_ARGV[@]}" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' codex exec --cd "$TEMP_DIR/wt" --sandbox workspace-write -c sandbox_workspace_write.network_access=true -c "sandbox_workspace_write.writable_roots=[\"$WORK/.git\"]" --add-dir "$WORK" --json - "$TEMP_DIR/wt/.solve-feature/coder.codex-prompt.md")" ]
  [ "$(cat "$TEMP_DIR/wt/.solve-feature/coder.codex-prompt.md")" = x ]

  # A worktree of a bare repo: the bare dir is the root, and its parent is no checkout to add.
  git clone -q --bare "$WORK" "$TEMP_DIR/b.git"
  git -C "$TEMP_DIR/b.git" worktree add -q "$TEMP_DIR/bwt" >/dev/null 2>&1
  cd "$TEMP_DIR/bwt"
  mkdir .solve-feature
  run bash -c '. "$1"; agent_cmd coder codex "" 5 x && printf "%s\n" "${AGENT_ARGV[@]}"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' codex exec --cd "$TEMP_DIR/bwt" --sandbox workspace-write -c sandbox_workspace_write.network_access=true -c "sandbox_workspace_write.writable_roots=[\"$TEMP_DIR/b.git\"]" --json -)" ]

  # The root is a TOML string: a quote or backslash in the path is escaped.
  mkdir "$TEMP_DIR/q\"b\\s" && cd "$TEMP_DIR/q\"b\\s" && git init -q && mkdir .solve-feature
  run bash -c '. "$1"; agent_cmd coder codex "" 5 x && printf "%s\n" "${AGENT_ARGV[@]}"' _ "$SCRIPTS/agent.sh"
  [[ "$output" == *"writable_roots=[\"$TEMP_DIR/q\\\"b\\\\s/.git\"]"* ]]
}

@test "agent_cmd: the codex reviewer runs in .solve-feature as its one writable root, the prompt file opening with the writable-directory paragraph" {
  mkdir .solve-feature
  run bash -c '. "$1"; agent_cmd reviewer codex "" 4 "Review PR #9." && printf "%s\n" "${AGENT_ARGV[@]}" "$AGENT_STDIN_FILE"' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' codex exec --cd "$WORK/.solve-feature" --sandbox workspace-write -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true --json - "$WORK/.solve-feature/reviewer.codex-prompt.md")" ]
  [ "$(cat "$WORK/.solve-feature/reviewer.codex-prompt.md")" = "$(printf 'Your shell starts in %s/.solve-feature, the only writable directory, where your report goes. The repository is %s: run your commands there (cd %s && ...).\n\nReview PR #9.' "$WORK" "$WORK" "$WORK")" ]
  run bash -c '. "$1"; agent_cmd reviewer codex o3 4 p && printf "%s\n" "${AGENT_ARGV[@]}"' _ "$SCRIPTS/agent.sh"
  [ "$output" = "$(printf '%s\n' codex exec --cd "$WORK/.solve-feature" --sandbox workspace-write -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true --json --model o3 -)" ]
}

@test "agent_coder_prompt: pi and codex get copilot's sentence naming the skill" {
  run bash -c '. "$1"; agent_coder_prompt pi 2' _ "$SCRIPTS/agent.sh"
  [ "$output" = "Use the solve-issue skill on 2." ]
  run bash -c '. "$1"; agent_coder_prompt codex .scratch/f/issues/open/01-a.md' _ "$SCRIPTS/agent.sh"
  [ "$output" = "Use the solve-issue skill on .scratch/f/issues/open/01-a.md." ]
}

@test "agent_model: pi and codex have no built-in default; afk.models.pi/codex.<role> when set; claude's defaults unchanged" {
  run bash -c '. "$1"; agent_model pi coder' _ "$SCRIPTS/agent.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run bash -c '. "$1"; agent_model codex reviewer' _ "$SCRIPTS/agent.sh"
  [ "$output" = "" ]
  echo '{"afk":{"models":{"pi":{"coder":"claude-sonnet-4"},"codex":{"reviewer":"o3"}}}}' > .coding-crew/config.json
  run bash -c '. "$1"; agent_model pi coder' _ "$SCRIPTS/agent.sh"
  [ "$output" = claude-sonnet-4 ]
  run bash -c '. "$1"; agent_model codex reviewer' _ "$SCRIPTS/agent.sh"
  [ "$output" = o3 ]
  run bash -c '. "$1"; agent_model claude coder' _ "$SCRIPTS/agent.sh"
  [ "$output" = sonnet ]
  run bash -c '. "$1"; agent_model claude reviewer' _ "$SCRIPTS/agent.sh"
  [ "$output" = opus ]
}

@test "agent_log_tail: each agent's final text from its JSON log, the raw last 20 lines otherwise" {
  local L="$TEMP_DIR/log"
  printf 'noise\n{"type":"system"}\n{"type":"result","result":"BLOCKED: x\\nline two"}\n' > "$L"
  run bash -c '. "$1"; agent_log_tail claude "$2"' _ "$SCRIPTS/agent.sh" "$L"
  [ "$output" = "$(printf 'BLOCKED: x\nline two')" ]
  printf '{"type":"assistant.message","data":{"content":"first"}}\n{"type":"tool"}\n{"type":"assistant.message","data":{"content":"last\\nmsg"}}\n' > "$L"
  run bash -c '. "$1"; agent_log_tail copilot "$2"' _ "$SCRIPTS/agent.sh" "$L"
  [ "$output" = "$(printf 'last\nmsg')" ]
  printf '{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"ask"}]}}\n{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"early"}]}}\n{"type":"tool_execution_start"}\n{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"done\\n"},{"type":"text","text":"twice"}]}}\n' > "$L"
  run bash -c '. "$1"; agent_log_tail pi "$2"' _ "$SCRIPTS/agent.sh" "$L"
  [ "$output" = "$(printf 'done\ntwice')" ]
  # A run that ends on a provider error ends on an assistant message with no text: the raw tail, not an earlier message.
  printf '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"early"}]}}\n{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"429"}}\n' > "$L"
  run bash -c '. "$1"; agent_log_tail pi "$2"' _ "$SCRIPTS/agent.sh" "$L"
  [[ "$output" == *'"errorMessage":"429"'* ]]
  printf '{"type":"item.completed","item":{"type":"agent_message","text":"early"}}\n{"type":"item.completed","item":{"type":"command_execution","text":"not me"}}\n{"type":"item.completed","item":{"type":"agent_message","text":"final\\nword"}}\n{"type":"turn.completed"}\n' > "$L"
  run bash -c '. "$1"; agent_log_tail codex "$2"' _ "$SCRIPTS/agent.sh" "$L"
  [ "$output" = "$(printf 'final\nword')" ]
  seq 1 30 > "$L"
  for a in claude copilot pi codex; do
    run bash -c '. "$1"; agent_log_tail "$2" "$3"' _ "$SCRIPTS/agent.sh" "$a" "$L"
    [ "$output" = "$(seq 11 30)" ] || { echo "$a: $output"; return 1; }
  done
}

# --- review-pr.sh ------------------------------------------------------------------------

@test "one claude reviewer call under timeout 30m with the read-only argv; the prompt names the files, the questions and the report" {
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "$(agent_calls)" -eq 1 ]
  [ "$(cat "$STATE/timeout.arg")" = 30m ]
  prompt=$(agent_prompt 1)
  [ "$(agent_call 1)" = "$(printf '%s\n' claude -p '<prompt>' --output-format json --max-budget-usd 4 --model opus --permission-mode bypassPermissions --tools Bash Read ToolSearch --settings '{"disableClaudeAiConnectors":true,"disableBundledSkills":true}')" ]
  grep -qF "$WORK/.solve-feature/pr-9.spec.md" <<<"$prompt"
  grep -qF "$WORK/.solve-feature/pr-9.diff" <<<"$prompt"
  grep -qF "https://github.com/o/r/pull/9" <<<"$prompt"
  grep -qF "deliver what the spec asks" <<<"$prompt"
  grep -qF "bug free" <<<"$prompt"
  grep -qF "Never edit, write, commit or change the tree." <<<"$prompt"
  grep -qF "Defects that only appear across issues exist" <<<"$prompt"
  grep -qF "Commit messages, PR text and progress notes are claims, not evidence." <<<"$prompt"
  grep -qF "Write your report to $WORK/.solve-feature/pr-9.review.json as your last action" <<<"$prompt"
  [ "$(cat .solve-feature/pr-9.spec.md)" = "$(printf '<details><summary>Spec</summary>\n\n# Spec body\n\n</details>')" ]
  [ "$(cat .solve-feature/pr-9.diff)" = "$(cat "$STATE/pr.diff")" ]
  [ "$(cat .solve-feature/.gitignore)" = '*' ]
  [ -z "$(git status --porcelain)" ]
}

@test "a body without a Spec block is the spec whole" {
  pr_view "$HEAD_OID" true "just a description\nline two"
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "$(cat .solve-feature/pr-9.spec.md)" = "$(printf 'just a description\nline two')" ]
}

@test "--agent copilot: the copilot reviewer argv, --model only from afk.models.copilot.reviewer; --agent other exits before gh" {
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9 --agent copilot
  [ "$status" -eq 0 ]
  [ "$(agent_call 1)" = "$(printf '%s\n' copilot -p '<prompt>' --allow-all-tools --no-color --output-format json --deny-tool write)" ]
  echo '{"afk":{"models":{"copilot":{"reviewer":"gpt-5"}}}}' > .coding-crew/config.json
  git commit -qam models; pr_view "$(git rev-parse HEAD)" true "spec"
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' SOLVE_FEATURE_AGENT=copilot run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "$(agent_flag 2 --model)" = gpt-5 ]
  : > "$STATE/gh.log"
  run bash "$SCRIPT" 9 --agent other
  [ "$status" -eq 1 ]
  [[ "$output" == *"other"*"codex"* ]]
  [ ! -s "$STATE/gh.log" ]
  [ "$(agent_calls)" -eq 2 ]
  # agent.sh's agent_known is the one list of agents.
  ! grep -qE 'case .*claude\|copilot' "$SCRIPT" "$REPO_ROOT/skills/solve-feature/scripts/solve-feature.sh"
}

@test "--agent pi: the read-only pi argv under timeout 30m with the prompt last and stdin /dev/null; --model from afk.models.pi.reviewer" {
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9 --agent pi
  [ "$status" -eq 0 ]
  [ "$(agent_call 1)" = "$(printf '%s\n' pi -p --mode json --tools read,bash '<prompt>')" ]
  [ "$(cat "$STATE/agent.1.stdin")" = /dev/null ]
  [ "$(cat "$STATE/timeout.arg")" = 30m ]
  grep -qF "Write your report to $WORK/.solve-feature/pr-9.review.json as your last action" <<<"$(agent_prompt 1)"
  echo '{"afk":{"models":{"pi":{"reviewer":"m1"}}}}' > .coding-crew/config.json
  git commit -qam models; pr_view "$(git rev-parse HEAD)" true "spec"
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' SOLVE_FEATURE_AGENT=pi run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "$(agent_flag 2 --model)" = m1 ]
  [ "$(cat .solve-feature/.gitignore)" = '*' ]
  [ -z "$(git status --porcelain)" ]
}

@test "--agent codex: the sandboxed codex argv in .solve-feature, the prompt file on stdin opening with the writable-directory paragraph then the unchanged review prompt" {
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9 --agent codex
  [ "$status" -eq 0 ]
  [ "$(agent_call 1)" = "$(printf '%s\n' codex exec --cd "$WORK/.solve-feature" --sandbox workspace-write -c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true --json -)" ]
  [ "$(cat "$STATE/timeout.arg")" = 30m ]
  prompt=$(agent_prompt 1)
  [ "$(head -1 <<<"$prompt")" = "Your shell starts in $WORK/.solve-feature, the only writable directory, where your report goes. The repository is $WORK: run your commands there (cd $WORK && ...)." ]
  [ "$(sed -n 2p <<<"$prompt")" = "" ]
  [ "$(sed -n 3p <<<"$prompt")" = "Review PR #9 (https://github.com/o/r/pull/9), checked out at HEAD, against its spec." ]
  grep -qF "Write your report to $WORK/.solve-feature/pr-9.review.json as your last action" <<<"$prompt"
  [ "$(cat .solve-feature/pr-9.reviewer.codex-prompt.md)" = "$prompt" ]
  [ -z "$(git status --porcelain)" ]
  echo '{"afk":{"models":{"codex":{"reviewer":"o3"}}}}' > .coding-crew/config.json
  git commit -qam models; pr_view "$(git rev-parse HEAD)" true "spec"
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9 --agent codex
  [ "$status" -eq 0 ]
  [ "$(agent_flag 2 --model)" = o3 ]
}

@test "HEAD not at the PR's head: exit 1 naming gh pr checkout, no agent" {
  pr_view 0123456789abcdef0123456789abcdef01234567 true "spec"
  run bash "$SCRIPT" 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh pr checkout 9"* ]]
  [ "$(agent_calls)" -eq 0 ]
}

@test "the reviewer dirtying or committing: exit 1 'reviewer changed the tree', nothing posted, no gh pr ready" {
  AGENT_DIRTY=1 REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"reviewer changed the tree"* ]]
  rm -f reviewer-dirt.txt
  AGENT_COMMIT=1 REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"reviewer changed the tree"* ]]
  ! grep -q 'POST' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "findings: inline where path:line is on the diff's right side, the rest in the body by severity, gaps listed, markers hashed, no ready" {
  REPORT_JSON='{"prd":"unmet","gaps":["no docs"],"findings":[
    {"severity":"HIGH","location":"lib.sh:2","issue":"breaks","fix":"guard it"},
    {"severity":"low","location":"lib.sh:9","issue":"nit","fix":"rename"}]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=unmet findings=2 (1 inline) ready=no" ]
  P="$STATE/payload.json"
  [ "$(jq -r .event "$P")" = COMMENT ]
  [ "$(jq '.comments | length' "$P")" -eq 1 ]
  [ "$(jq -c '.comments[0] | {path, line, side}' "$P")" = '{"path":"lib.sh","line":2,"side":"RIGHT"}' ]
  m1=$(marker_of 'HIGH|lib.sh:2|guard it') m2=$(marker_of 'LOW|lib.sh:9|rename')
  [ "$(jq -r '.comments[0].body' "$P")" = "$(printf '**HIGH** — breaks\n\nFix: guard it\n\n<!-- %s -->' "$m1")" ]
  body=$(jq -r .body "$P")
  [ "$(head -1 <<<"$body")" = "review-pr: prd unmet, 2 finding(s)" ]
  grep -qxF -- '### Gaps' <<<"$body"
  grep -qxF -- '- no docs' <<<"$body"
  grep -qxF -- '### LOW' <<<"$body"
  grep -qxF -- "- \`lib.sh:9\` — nit — Fix: rename <!-- $m2 -->" <<<"$body"
  ! grep -q '### HIGH' <<<"$body"
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "prd met with no CRITICAL/HIGH finding on a draft: review posted and gh pr ready; a non-draft is 'already'" {
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=met findings=0 (0 inline) ready=yes" ]
  [ "$(jq -r .body "$STATE/payload.json")" = "review-pr: prd met, 0 finding(s)" ]
  [ "$(jq '.comments | length' "$STATE/payload.json")" -eq 0 ]
  grep -qx 'pr ready 9' "$STATE/gh.log"
  pr_view "$HEAD_OID" false "spec"; : > "$STATE/gh.log"
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=met findings=0 (0 inline) ready=already" ]
  grep -q 'POST' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "a MEDIUM finding still flips ready; CRITICAL or high (any case) does not" {
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[{"severity":"MEDIUM","location":"lib.sh:2","issue":"i","fix":"f"}]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=met findings=1 (1 inline) ready=yes" ]
  : > "$STATE/gh.log"
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[{"severity":"CRITICAL","location":"lib.sh:2","issue":"i","fix":"f"}]}' run bash "$SCRIPT" 9
  [ "${lines[-1]}" = "REVIEW: prd=met findings=1 (1 inline) ready=no" ]
  REPORT_JSON='{"prd":"met","gaps":[],"findings":[{"severity":"high","location":"x","issue":"i","fix":"f"}]}' run bash "$SCRIPT" 9
  [ "${lines[-1]}" = "REVIEW: prd=met findings=1 (0 inline) ready=no" ]
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "a finding whose marker is already on the PR is skipped; all skipped still posts the one-line body" {
  m1=$(marker_of 'HIGH|lib.sh:2|guard it') m2=$(marker_of 'LOW|lib.sh:9|rename')
  printf '[{"body":"old <!-- %s -->"}]' "$m1" > "$STATE/reviews.json"
  REPORT_JSON='{"prd":"unmet","gaps":[],"findings":[
    {"severity":"HIGH","location":"lib.sh:2","issue":"breaks","fix":"guard it"},
    {"severity":"LOW","location":"lib.sh:9","issue":"nit","fix":"rename"}]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=unmet findings=1 (0 inline) ready=no" ]
  ! grep -q "$m1" "$STATE/payload.json"
  grep -q "$m2" "$STATE/payload.json"
  printf '[{"body":"x <!-- %s -->"}]' "$m2" > "$STATE/comments.json"
  REPORT_JSON='{"prd":"unmet","gaps":[],"findings":[
    {"severity":"HIGH","location":"lib.sh:2","issue":"breaks","fix":"guard it"},
    {"severity":"LOW","location":"lib.sh:9","issue":"nit","fix":"rename"}]}' run bash "$SCRIPT" 9
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=unmet findings=0 (0 inline) ready=no" ]
  [ "$(jq -r .body "$STATE/payload.json")" = "review-pr: prd unmet, 0 finding(s)" ]
}

@test "no report, an unparseable one, or prd not met|unmet: no POST, no ready, exit 1 naming the log" {
  for r in "" '{not json' '{"prd":"maybe"}'; do
    REPORT_JSON="$r" run bash "$SCRIPT" 9
    [ "$status" -eq 1 ]
    [[ "$output" == *"pr-9.review.log"* ]]
  done
  ! grep -q 'POST' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
  [ -s .solve-feature/pr-9.review.log ]
}

@test "a failing /reviews POST exits 1 with gh's stderr and no gh pr ready" {
  GH_POST_FAIL=1 REPORT_JSON='{"prd":"met","gaps":[],"findings":[]}' run bash "$SCRIPT" 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 422"* ]]
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "a non-numeric PR argument is a usage error before gh" {
  run bash "$SCRIPT" abc
  [ "$status" -eq 1 ]
  [ ! -f "$STATE/gh.log" ]
}
