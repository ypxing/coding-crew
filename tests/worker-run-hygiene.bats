#!/usr/bin/env bats

# Headless workers share a machine with sibling workers: a check run in the background, a
# `/tmp/<name>` file, or a `pkill` of a process the worker did not start each broke a
# neighbour's run. The rules live in solve-issue (every runner needs them); the claude
# crew-coder's Platform Notes add the tools a headless `claude -p` worker must not reach for.

load helpers/render

setup() {
  BODY="$(rendered_skill solve-issue claude)"
  STEP4=$(awk '/^### 4\./{f=1;next} /^### /{f=0} f' "$BODY")
  STEP5=$(awk '/^### 5\./{f=1;next} /^### /{f=0} f' "$BODY")
}

@test "solve-issue: checks run in the foreground and the worker waits for them" {
  echo "$STEP4$STEP5" | grep -qi 'foreground'
  echo "$STEP4$STEP5" | grep -qi 'wait for'
}

@test "solve-issue: Step 5 is the one full-suite run; between edits only what the change touches" {
  echo "$STEP5" | grep -qi 'the one full-suite run'
  echo "$STEP4" | grep -qi 'only what your change touches'
}

@test "solve-issue: temp files live under the project root, never a shared /tmp path" {
  grep -qi 'temp files go under .*PROJECT_ROOT' "$BODY"
  grep -qF '/tmp/<name>' "$BODY"
}

@test "solve-issue: never kill a process the worker did not start" {
  grep -qi 'never kill a process you did not start' "$BODY"
}

@test "claude crew-coder: no Monitor, no ScheduleWakeup, no background runs for checks" {
  f="$(coder_variant claude)"
  grep -q 'Monitor' "$f"
  grep -q 'ScheduleWakeup' "$f"
  grep -qi 'background' "$f"
}

@test "no other platform's crew-coder names Monitor or ScheduleWakeup" {
  for p in pi codex copilot; do
    ! grep -qE 'Monitor|ScheduleWakeup' "$(coder_variant "$p")"
  done
}

@test "neither body tells the worker to read in ranges or to skip the Step 5 run" {
  for f in "$BODY" "$(coder_variant claude)"; do
    ! grep -qiE 'read .*(in|by) (line )?ranges|offset.*limit|skip (the )?step 5' "$f"
  done
}
