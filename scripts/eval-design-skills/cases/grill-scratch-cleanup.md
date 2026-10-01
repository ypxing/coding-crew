---
skill: crew-grill
stage: round1
repo_ref: 9113947
---
## Request
.scratch/ keeps filling up with test-scripts-* directories — I count 23 in my clone right now. Add a way to automatically clean up stale scratch directories.

## Reference judgement
Facts (tests/orchestrator/helpers/sprint.mjs at this ref): the dirs come from two mkdtempSync calls (:45 SCRIPTS_BASE, :193 privateScripts) and are already removed in after() hooks (:52, :190); strays are runs killed before those hooks fire (Ctrl-C, timeout, cancelled run). They must stay at that depth under the repo: ensure-deps.sh walks up a fixed number of parents (comment at :40-43), so moving them to os.tmpdir() breaks the fixtures. .scratch/ is gitignored, so the count is the user's observation (23), not visible in a fresh checkout. Proportionate: a few lines in the helper that sweep stale test-scripts-* (age-guarded, since parallel shards and worktrees have live dirs) before creating new ones, or simply deleting them by hand now and then — a few MB of gitignored dirs. Overbuilt: a standalone cleanup script/CLI flag, a CI job, a generic .scratch GC. Wrongly built: moving the dirs to os.tmpdir(), or a sweep that is not limited to test-scripts-* (.scratch also holds feature issues).
