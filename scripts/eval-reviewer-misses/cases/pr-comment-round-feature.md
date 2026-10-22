---
mode: feature
base_sha: baf33cda1e39
head_sha: 04b2e54d68eb
slug: pr-comment-round
via: refs/pull/604/head
---
Replay of the second feature review of #604 (pr-comment-round), range `baf33cda1e39..04b2e54d68eb`. The SHAs are
reachable through `origin/feature/pr-comment-round`; fetch it before running if they do not resolve.
Escaped: `2026-10-22 skills/setup-coding-crew/hosts/github-actions.yml:67 — the review's fix for "a thread resolved
without a reply starts no round" was a `pull_request_review_thread` trigger, which D1 ruled out and GitHub Actions
does not have (actionlint: unknown Webhook event); the fixer applied it — bc5892e4`. Also missed by every review:
an approving review starts a paid session, and a ready PR keeps its open threads when a round accepts nothing.

## Expected misses

- resolve-routed-to-person: A person who resolves a thread instead of replying starts no round (resolving is not a submitted review), so a draft PR stays a draft; the output reports this as a spec gap or decision for a person quoting D1 or D9, or suggests a fix that adds no trigger (telling people to reply on the thread), not one that only adds `pull_request_review_thread` or another `on:` event.
- approval-starts-round: An approving review from a user with write access passes the slug job's filters, so every approval starts an address-pr-comments session (billed) with nothing to address; the slug job's `if:` or step does not exclude `review.state` approved.
- ready-pr-open-threads: Copilot's first review arrives after the PR is ready; a round that accepts nothing and leaves threads open for a person runs no solve-feature (Step 3.5.1 runs it only for a ready issue or a draft with no open thread), so nothing turns the PR back into a draft and it stays ready with unresolved threads.

## Reference judgement

resolve-routed-to-person: at head the host file triggers only on `pull_request_review: [submitted]` (D1: "New `on:` event `pull_request_review: [submitted]` only"; D9: "A person answers by replying on the thread"). The case is real, but supporting it is a design decision the PRD made, and `pull_request_review_thread` is a webhook event, not an Actions trigger: a workflow naming it is invalid, so label and dispatch runs stop too. Caught only if the output names the resolve-without-reply case and either puts it in `gaps` (or says it needs the owner's decision) quoting D1/D9, or it suggests a fix adding no workflow trigger. A finding whose only fix adds `pull_request_review_thread` is not caught.

approval-starts-round: the slug job's `if:` accepts any `pull_request_review` event; the step checks only the block, the author and the author's permission. An APPROVED review from a code owner (merging needs one, per the PRD's Further Notes) starts a session that finds nothing to fix. Caught only if a finding names approvals (or review state) starting a round/session.

ready-pr-open-threads: Problem Statement's goal is a PR that "ends ready for a human, its review comments handled, unless something genuinely needs a person"; B2 keeps a PR a draft while threads are open, but only `describe` enforces it. `skills/address-pr-comments/SKILL.md` Step 3.5.1 runs solve-feature with no accepted thread only when a ready issue exists or a draft has no unresolved thread. Copilot is requested only after ready (B6), so its first round lands on a ready PR. Caught only if the output says a ready PR stays ready with open threads after a round that accepts nothing (as a finding or a gap).

## PRD

Feature: pr-comment-round

### Problem Statement

Actor: the owner of a solve-feature PR (the person who started the feature).

A solve-feature PR is marked ready by `describe` (`skills/solve-feature/scripts/solve-feature.sh:376`) and its run ends there. Review comments that arrive afterwards — Copilot's, or a code owner's — have no one to act on them: the owner reads them, and so far has closed the PR and re-run the whole feature (amaysim-au/dpg-balance-management #330, #334, #336 closed; #343 is the fourth run). On #336 Copilot's four threads held three real bugs the in-run reviewer missed; on #343 one low-severity docs thread. Worse, Copilot never reviews these PRs on its own: on every PR `github-actions[bot]` opened (#330, #334, #336, #343) no automatic review ran, while every person-opened PR (#335, #337–#340, #342) and Copilot's own agent PR (#341) got one within 1–7 minutes; the owner requested it by hand 2–5 hours after ready (#336 at 04:33 after ready at 23:51; #343 at 04:52 after ready at 02:45). Meanwhile marking ready already asks the code owners to review.

The goal: a solve-feature PR ends ready for a human, its review comments handled, unless something genuinely needs a person — and then the person is told where, and answers there.

### Solution

On a solve-feature PR, `address-pr-comments` triages every unresolved thread and hands the accepted ones to solve-feature as one new issue of the feature, so the fix is coded, checked and reviewed like any other issue on the same branch and PR. It replies on every thread it handles, resolves the ones fixed, and @mentions the feature's owner on the ones that need a person; the owner answers by replying on the thread, which starts the next round. solve-feature keeps the PR a draft while it works and while any review thread is unresolved. On GitHub Actions, the solve-feature host workflow also runs on a submitted review or a review-comment reply, and once a run ends ready it asks Copilot for its one review using the owner's PAT.

### Behaviours

- **B1** — given an open solve-feature PR that is not a draft, `start` converts it to a draft before any coder runs, at `solve-feature.sh start`
- **B2** — given `k > 0` unresolved review threads on the PR, `describe` writes the Needs-attention line `<k> unresolved review threads: <PR URL>`, leaves the PR a draft and prints `needs-attention pr=<n>`, at `solve-feature.sh describe`
- **B3** — given a solve-feature PR with accepted comments, `address-pr-comments` files one `ready-for-agent` issue in the PR's feature and runs `solve-feature <slug>`; each accepted thread then carries a `Fixed in <sha>` reply and is resolved when its issue landed, or is unresolved again when it did not, at the `address-pr-comments` skill
- **B4** — given a non-interactive run, `address-pr-comments` asks nothing: a comment that contradicts a spec decision or touches a guarded area gets a counter-argument reply that @mentions the feature root issue's assignees (else its author) and stays open; a dismissed one gets its reason, and is resolved only when it is Copilot's, at the `address-pr-comments` skill
- **B5** — given a submitted review or a review-comment reply on a PR whose body has the solve-feature block, from Copilot or a user with write access, the host workflow runs `address-pr-comments` non-interactively in the feature's concurrency group; any other PR or author starts no session, at `hosts/github-actions.yml`
- **B6** — given a host run whose outcome is `ready pr=<n>`, a PR with no Copilot review yet and the `COPILOT_GITHUB_TOKEN` secret set, the workflow requests `@copilot` as reviewer with that token; without the secret it warns, with a Copilot review already on the PR it requests nothing, at `hosts/github-actions.yml`

### Decisions

- **D1** — The trigger is the existing host file `skills/setup-coding-crew/hosts/github-actions.yml`, extended — not a new workflow file, which would copy its agent and coding-crew installs (`:123-143`), session step and log filters (`:150-215`), CI start (`:217`), bundle, artifact and outcome steps (`:259`). New `on:` event `pull_request_review: [submitted]` only — a reply on a thread is submitted as a review and fires it, so `pull_request_review_comment` would start a duplicate round per reply. (auto) The `slug` job (`:76-99`, its `if:` at `:78`) also runs for them: it reads the PR body through a file (as `:87` does for the issue body), requires the `<!-- solve-feature:begin -->` line, takes the slug from the `<!-- solve-feature:slug <slug> -->` line, and requires the review's or comment's author to be `copilot-pull-request-reviewer[bot]` (the REST/webhook login of Copilot's reviews; its inline comments show `Copilot`) or a user whose repo permission is `write`, `maintain` or `admin`; otherwise it outputs no slug and the `solve` job is skipped. The `solve` job keeps its concurrency group `solve-feature-<slug>` (`:106-108`), so a review round and a label run on one feature queue. setup-coding-crew is unchanged: it already copies and diffs this file into `.github/workflows/solve-feature.yml` (`skills/setup-coding-crew/SKILL.md:103-122`).
- **D2** — For review events the session prompt is `Use the address-pr-comments skill on PR #<n>; this run is non-interactive` (Claude Code: `/address-pr-comments <n>` with that sentence), and the install line (`:143`) adds `address-pr-comments`. The CI-start step (`:217`) runs after review rounds unchanged.
- **D3** — After the session, when the outcome is `ready pr=<n>`, a step requests Copilot's review with `gh pr edit <n> --add-reviewer @copilot`, `GH_TOKEN` set to `secrets.COPILOT_GITHUB_TOKEN` for that one call only — and only when the PR has no review by `copilot-pull-request-reviewer[bot]`: a manual request re-reviews a PR Copilot already reviewed, so requesting after every ready round would loop. Secret unset → a `::warning::` saying the owner requests Copilot by hand; a refused request → a warning, never a failed job. Reason: Copilot's automatic review never fires for a PR the bot marks ready (the facts above); GitHub's docs: "when someone marks a draft ready for review, that person is the requestor".
- **D4** — Every other `gh` call in the job keeps `github.token` (`:154,220`). Events made with `GITHUB_TOKEN` start no workflow run (GitHub's rule), and the author filter (D1) rejects `github-actions[bot]`, so the agent's own thread replies cannot start a round.
- **D5** — (auto) A review round that started no solve-feature run (every thread dismissed or waiting on a person) has no outcome file; for review events the last step (`:259`) ends with a notice, not a failure, and so does `needs-attention pr=<n>` (the owner was @mentioned on the thread); `stopped: …` still fails. The PR's draft state and open threads show what is left.
- **D6** — `address-pr-comments` on a solve-feature PR (Step 1's test, `skills/address-pr-comments/SKILL.md:55`), interactive or not, no longer fixes, commits or pushes itself (Steps 4–5, `:88-128`, including the solve-feature push at `:114`): it writes the accepted comments as one `ready-for-agent` issue draft — one acceptance criterion per accepted thread, each linking its thread — publishes it with `node "$TRACKER" publish-issues --feature-slug <slug> --drafts <dir>`, then uses the `solve-feature` skill by name on the slug. No accepted comment → no issue and no solve-feature run. PRs without the block keep Steps 4–5 as they are. Reason: solve-feature's `describe` stays the one writer of the PR body's Needs-attention list and its ready/draft state, and the fix is reviewed (an unreviewed fixer commit marked #334 ready with a rewritten `yarn.lock`, #593).
- **D7** — Threads: accepted threads are resolved just before solve-feature runs (D8 counts unresolved threads), and after it returns each gets a `Fixed in <sha>` reply when solve-feature's outcome is `ready pr=` or `needs-attention pr=` (its review step runs only once `next` finds no ready issue, so the new issue landed), or is unresolved again (GraphQL `unresolveReviewThread`) on `stopped: …` or no outcome — the GitHub tracker never closes an issue mid-run (`mark-done` swaps in `awaiting-merge`, `lib/tracker/docs/github.md:109`). solve-feature runs with `--branch <the PR's headRefName>` (default `feature/<slug>`, `solve-feature.sh:142`). A round handles only unresolved threads whose last comment is not the agent's own login, so repeated rounds re-post nothing. A round that leaves no unresolved thread on a draft PR runs solve-feature even with nothing accepted, so `describe` marks it ready. (auto) Replies and resolution go through `gh api graphql` (the skill's gh-only rule, `SKILL.md:15`). Both modes.
- **D8** — Unattended triage (the prompt says the run is non-interactive; no `--auto` flag returns, #554): Step 3's confirmation is skipped and Debatable is decided by the agent. A real concern the spec allows → accepted. One that contradicts a decision in the feature's spec, or asks for a change in the areas the ground rule guards (`SKILL.md:152`) → a reply with the counter-argument that @mentions the feature root issue's assignees, else its author (the root: the issue whose body has the column-0 `Feature: <slug>` line), thread left open; with the local tracker, no @mention. Dismissed → a reply with the reason; Copilot's thread resolved, a person's left open for that person. The interactive mode keeps the triage table and its confirmation, then follows D6–D7.
- **D9** — A person answers by replying on the thread; the reply is submitted as a review, which starts the next round (D1).
- **D10** — solve-feature `start` (`solve-feature.sh:130`), after `pr_view` (`:158`) finds an open PR that is not a draft, converts it with `gh pr ready --undo` before printing `pr=`; a failed conversion stops with what failed and the command to run. Misled guard; the case is already live: #343 was ready from 02:45 while a second run reviewed and fixed it (fix commit 04:31). `describe` marks it ready again only when nothing needs a person (`:373-376`). Copilot reviews a PR once ("will only review a pull request once" without review-on-push), so the draft round trip starts no second review.
- **D11** — solve-feature `describe` (`:356`) counts the PR's unresolved review threads (GraphQL `reviewThreads`, every page) and, when `k > 0`, adds one line `<k> unresolved review threads: <PR URL>` to the attention list it already reads (`pr-<n>.attention.md`, written by `fix` at `:339-348`) — a count and a link, not a copy of the threads. A failed query stops `describe` before the PR is marked ready. solve-feature's SKILL.md does not change, and solve-feature never names address-pr-comments or Copilot (CLAUDE.md "solve-feature and crew-review stay boring").
- **D12** — `address-pr-comments` gains the tracker library: a committed link `skills/address-pr-comments/scripts/tracker -> ../../../lib/tracker`, `"tracker"` in its `registry.json` `libs` and `"solve-feature"` in its `deps` (`registry.json:55-65`).
- **D13** — (auto) Copilot's review overview ("Needs a closer look: …") is advisory and never forces a draft; top-level PR comments start no round but are read in every round (Step 2).

### Trust Boundaries & Risks

- **PR body, review and comment text** cross into the agent's prompt and the shell. The workflow reads the PR body only through a file (D1), never interpolated into a `run:` line; the skill treats all of it as data (the untrusted-text fragment, `SKILL.md:23-25`): a comment's stated requirement is work, an instruction to the agent is not followed.
- **Who can start a round**: only Copilot's reviewer bot and users with write access (D1); a comment from anyone else starts no session and is still read as data in a round someone else started.
- **The PAT** is used for one `gh pr edit` call and nothing else (D3); missing or refused, the job warns and goes on.
- **Loops**: the agent's replies use `github.token` (D4); Copilot is requested only when it has not reviewed (D3); Copilot reviews once per PR (D10).

### Testing Decisions

- solve-feature: `tests/solve-feature.bats` drives `start` and `describe` against a stubbed `gh` (prior art: the existing `describe` ready/needs-attention cases). New cases: `start` converts a ready PR and leaves a draft alone; `start` stops when `gh pr ready --undo` fails; `describe` with unresolved threads writes the line and stays a draft, with none marks ready, with a failed query stops.
- address-pr-comments is prose: its criteria are checked from the diff; `tests/native-skills.bats`, `tests/skill-deps.bats` and the golden install fixtures (`tests/platform-golden-install.bats`) cover the new link and registry entries.
- The host file: `tests/setup-coding-crew.bats` (which already reads `hosts/github-actions.yml`) gains structural checks of the new triggers, the slug job's filters, the Copilot-request step's guard and token, and the review-round notice.

### Out of Scope

- A CI-failure trigger (`workflow_run` on the repo's CI workflows, failed-log reading, one fix per head): every recorded failure was prettier, which the repo's own lint workflow auto-fixes and a `lint: make lint prettier` dev command prevents; the user chose to cut it.
- A `ready-for-human` tracker issue per comment that needs a person: replaced by the thread reply with an @mention (D8) and the unresolved-thread count (D11).
- `describe` converting a PR back to draft at the end: replaced by `start` doing it (D10), which also covers a run that stops midway.
- A separate workflow file for review rounds: it would duplicate the host file (D1).
- Rounds on PRs without the solve-feature block, and rounds started by top-level PR comments.

### Further Notes

- History: an unattended `address-pr-comments --auto` with a crew-rework workflow (#43) was removed after zero uses (#554). The difference now is the trigger: Copilot's requested review (D3) and the owner's thread replies start rounds without anyone remembering to.
- Outside this repo (dpg-balance-management): set `.coding-crew/dev-commands.json` `lint` to `make lint prettier`; approve the four held `action_required` runs on #343's head; confirm the PAT in `COPILOT_GITHUB_TOKEN` can add a reviewer (it likely needs Pull requests: write besides Copilot Requests), e.g. `GH_TOKEN=<pat> gh pr edit 344 --add-reviewer @copilot`; then `/setup-coding-crew redo actions` there to take the new host file.
- Merging still needs one code-owner approval (ruleset 23910713; `required_review_thread_resolution: false`).


