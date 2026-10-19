# smoke-demo.bash — a stubbed demo for scripts/smoke-crew-afk.sh: a local upstream repo pinned at its main
# ($UP, $PIN), a demo dir laid out like scripts/smoke-crew-afk/demo/ ($DEMO, slug report-cli), a `gh` stub and a
# CREW_SMOKE_DISPATCH stub in $STUB that log to $BATS_TEST_TMPDIR/calls. The dispatch stub's `dispatch` adds a
# worktree, writes solve-feature's files there ($OUTCOME, default `ready pr=9`; two findings) and prints its
# worktree and a short-lived pid, so no agent CLI is called (its argv, one per line, goes to
# $BATS_TEST_TMPDIR/dispatch-argv); its `wait` prints crew-afk's status line for the run,
# with $WAIT_COST (default ` cost=$1.25 (3 min)`) after the outcome. $GH_OPEN_PR is what `gh pr list` answers.
# An `npx` stub stands in for `npx skills add` on the --via npx route.

make_smoke_demo() {
  UP="$BATS_TEST_TMPDIR/upstream"
  git init -q -b main "$UP"
  echo one > "$UP/a.txt"
  git -C "$UP" add -A && git -C "$UP" -c user.email=t@t -c user.name=t commit -qm one
  PIN=$(git -C "$UP" rev-parse HEAD)

  DEMO="$BATS_TEST_TMPDIR/demo"
  mkdir -p "$DEMO/feature/issues/open"
  echo "$UP" > "$DEMO/repo"
  echo "$PIN" > "$DEMO/sha"
  echo report-cli > "$DEMO/slug"
  printf '# the demo project checks\ntest -f a.txt\n\ntest -f ok.txt\n' > "$DEMO/check"
  echo "# PRD" > "$DEMO/feature/PRD.md"
  echo "# issue" > "$DEMO/feature/issues/open/01-one.md"

  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB"
  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$BATS_TEST_TMPDIR/calls"
[ "$1 $2" != "pr list" ] || echo "${GH_OPEN_PR:-}"
SH
  cat > "$STUB/dispatch" <<'SH'
#!/usr/bin/env bash
if [ "$1" = wait ]; then
  echo "wait $2" >> "$BATS_TEST_TMPDIR/calls"
  echo "$2: ${OUTCOME:-ready pr=9}${WAIT_COST- cost=\$1.25 (3 min)}"
  exit 0
fi
echo "dispatch $* (in $PWD)" >> "$BATS_TEST_TMPDIR/calls"
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/dispatch-argv"
wt="$BATS_TEST_TMPDIR/wt"
rm -rf "$wt"
git worktree add -q --detach "$wt" >&2
touch "$wt/ok.txt"
mkdir -p "$wt/.coding-crew/solve-feature"
# A different cost from wait's: the smoke takes its cost from the wait line, not from the log.
printf 'starting\n{"type":"result","subtype":"success","total_cost_usd":9.99}\n' > "$wt/.coding-crew/solve-feature/run.log"
echo '{"findings":[{"severity":"LOW"},{"severity":"HIGH"}]}' > "$wt/.coding-crew/solve-feature/pr-9.review.json"
echo "${OUTCOME:-ready pr=9}" > "$wt/.coding-crew/solve-feature/outcome"
sleep 0.2 &
echo "worktree=$wt"
echo "log=$wt/.coding-crew/solve-feature/run.log"
echo "pid=$!"
SH
  # `npx skills add`: logs its argv and dir, then writes what a single-agent install writes — the skills
  # dir its -a agent reads and skills-lock.json at the repo root.
  cat > "$STUB/npx" <<'SH'
#!/usr/bin/env bash
echo "npx $* (in $PWD) DISABLE_TELEMETRY=${DISABLE_TELEMETRY:-}" >> "$BATS_TEST_TMPDIR/calls"
while [ $# -gt 0 ]; do [ "$1" = -a ] && agent=$2; shift; done
case "$agent" in claude-code) dir=.claude/skills ;; *) dir=.agents/skills ;; esac
mkdir -p "$dir/crew-afk/scripts" "$dir/solve-feature"
echo '#!/usr/bin/env bash' > "$dir/crew-afk/scripts/crew-afk.sh"
echo '{}' > skills-lock.json
SH
  chmod +x "$STUB"/*
  export PATH="$STUB:$PATH" CREW_DEMO_DIR="$DEMO" CREW_SMOKE_DISPATCH="$STUB/dispatch"
}
