#!/usr/bin/env bats

# review-pr.sh — one read-only agent reviews a checked-out PR against the spec in its body, posts one
# COMMENT review and flips a draft to ready when the spec is met with no CRITICAL/HIGH finding; agent.sh
# beside it owns the coding-agent axis (argv, coder prompt, model) for review-pr and solve-feature.
#
# A temp repo whose HEAD is the stubbed PR's head; `gh`, `claude`, `copilot` and `timeout` are stubs on
# PATH logging their argv into $STATE. The agent stub writes the report its prompt names from
# $REPORT_JSON, or none; it can also dirty or commit the tree.

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
  # Both agents: argv one per line in agent.<k>; the report path is the prompt's `Write your report to <path>`.
  for a in claude copilot; do
    cat > "$STUB/$a" <<EOF
#!/usr/bin/env bash
k=\$(( \$(ls "\$STATE" | grep -c '^agent\.[0-9]*\$') + 1 ))
printf '%s\n' "$a" "\$@" > "\$STATE/agent.\$k"
report=\$(printf '%s\n' "\$2" | sed -n 's/^Write your report to \(.*\) as your last action.*/\1/p')
[ -z "\${REPORT_JSON:-}" ] || printf '%s\n' "\$REPORT_JSON" > "\$report"
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
