---
mode: feature
base_sha: da217ddfbb59
head_sha: 9b65719a
slug: solve-feature-no-pr
via: refs/pull/672/head
---
Replay of the second feature review of #672 (solve-feature-no-pr, opus reviewer), range `da217ddfbb59..9b65719a`.
It reported two other real findings (land's fresh-clone advice in local mode, the guide's missing outcomes), fixed in
aeecc7cb. Escaped: `2026-10-29 skills/solve-feature/scripts/solve-feature.sh:118 — the local body file is read without
the CRLF strip the gh path has, so describe drops the notes section — d4099dfc` and `2026-10-29
skills/solve-feature/scripts/solve-feature.sh:347 — a failed first local body write dies with the issue already closed
— d4099dfc`. Both found by Copilot code review on an internal mirror's PR.

## Expected misses

- crlf-local-body-notes: `pr_body_read` strips `\r` only on the GitHub path (`:118`), not when it reads the local body file, so a local body a person saved with CRLF line endings no longer matches the notes markers and `describe` (or `post_notes`) drops or duplicates the notes section.
- local-body-write-closed-issue: when `land`'s first `pr_body_write local` fails (`:347`), it `die`s after the coder already closed the issue: nothing reopens it, so a re-run skips the issue and, if it was the last, never resumes review; the message does not say how to recover.

## Reference judgement

crlf-local-body-notes: `pr_body_read` (`solve-feature.sh:115-121` at head) has two branches under one comment saying a person-edited body can come back with CRLF, "which no marker match would see"; the gh branch pipes through `tr -d '\r'`, the local branch (`tail -n +2 "$(local_body)" | sed …`) does not. The local file is meant for a person to edit before opening the PR (the spec's "a note a person deleted stays deleted"). With CRLF, `describe`'s `sed -n "\|^$NOTES_BEGIN\$|,…"` (`:532`) matches nothing, so the rewritten body loses every note; `post_notes`' `grep -qxF "$NOTES_END"` misses and appends a second section. Caught only if a finding says the local read path does not normalise CRLF (or line endings) and names the notes being lost or duplicated. A finding about CRLF on the GitHub path is not it.

local-body-write-closed-issue: in `land` (`:306`) the coder has already closed `$REF` (`mark-done`) when `pr_body_write local … || die "cannot write $(local_body)"` (`:347`) runs. The publish path reopens on the equivalent failure (`pr_create_failed`, `:294`, via `reopen_ref`); this path does not. After the cause is fixed, `next` never returns the closed issue, and with no local body `start` reports no PR, so `next` stops "nothing landed". Caught only if a finding says this failure leaves the issue closed (or counted landed) with no way back on a re-run, or that it should reopen as `pr_create_failed` does. Saying only that the message is vague is not it.

## PRD

### 671-solve-feature-build-a-feature-without-pushing-or-opening-a-pr-when-the-user-level-config-sets-solvefeature-publish-false — solve-feature: build a feature without pushing or opening a PR when the user-level config sets solveFeature.publish: false

Feature: solve-feature-no-pr

#### What to build

A user whose `~/.coding-crew/config.json` sets `{"solveFeature":{"publish":false}}` runs `/solve-feature <slug>` (or `/crew-afk <slug>`, which dispatches it) as today and gets a reviewed, fixed local branch, the PR body as a file, and a `ready branch=<b>` / `needs-attention branch=<b>` outcome — with no `git push` and no `gh pr` call. Requested by one user who wants nothing to leave the machine; they push the branch and open the PR themselves later.

The change is in `skills/solve-feature/scripts/solve-feature.sh` (every step: `start`, `next`, `land`, `sync`, `reviewed`, `fix`, `describe`) and `skills/solve-feature/SKILL.md`. Today the PR is the only store of the body and its notes: `post_notes` (`solve-feature.sh:201`) and `describe` (`:467`) read and write it with `gh pr view`/`gh pr edit`. This issue adds one pair of body read/write functions so those callers stay as they are, backed by gh when publishing and by a local body file when not (D7).

(auto) The local body file is `.coding-crew/solve-feature/local-pr-<branch, `/` → `_`>.md`, not `pr-body.md`: `land` already writes `pr-body.md` as its draft body in publish mode (`solve-feature.sh:316-317`) and nothing deletes it, so a stale one would read as a PR; keyed by branch as `gh pr view "$BRANCH"` is (`:99`), a second feature or `--branch` run in the same checkout never reads another's. `start`'s cleanup glob (`pr-*`, `:55`) does not match it.
(auto) The file's first line is `# <title>`: `land`'s `pr_title` when it creates it, replaced by write-pr's title when `describe` writes it (as `gh pr edit --title` does, `:498`); the body follows, so the person opening the PR has both.
(auto) `sync` merges `origin/<branch>` only when that ref exists (as `land`/`fix` guard theirs with `git fetch origin "$BRANCH" &&`), since in no-PR mode origin usually lacks the branch and the unguarded merge at `:355` would die; in no-PR mode `sync` runs the checks only when its merges moved HEAD, in place of the `is-ancestor HEAD origin/$BRANCH` test (`:359`), which there means "needs pushing".
(auto) Pushes are skipped at each call site, not inside `push()`, and every stop message reached in no-PR mode drops its push or gh wording: `hand_back` (`:262`) and `pr_create_failed` never claim work "pushed to $BRANCH", and recovery text at `:158`, `:364`, `:425` and `post_notes`' `gh pr edit` hint (`:205`) names the local file or a plain re-run instead.

#### Decisions

- **D1** — Nothing leaves the machine: every `git push` is skipped (`solve-feature.sh:152,160` in start, `:307` land, `:364` sync, `:425` fix), and so is `gh pr create` (`:318`). Fetching origin and merging `origin/<default>` and `origin/<branch>` stays as today — those only read.
- **D2** — The setting is read from the user-level `$HOME/.coding-crew/config.json` only, never the project's `.coding-crew/config.json` (unlike `model()`, `:124-131`, which reads both). A runner never has the user-level file, so an Actions run cannot pick it up and lose its unpushed commits with the runner; the Actions job fails on anything but `ready pr=<n>` (`.github/workflows/crew-solve-feature.yml:41`).
- **D3** — One pair of functions owns the PR body (read, write): gh on `pr=<n>` when publishing, the branch's local body file when not. `post_notes` and `describe` call only that pair, so the notes-section logic is not duplicated.
- **D4** — The outcome is `ready branch=<b>` or `needs-attention branch=<b>`, same words as today with `branch=` in place of `pr=`. crew-afk relays the outcome line verbatim (`skills/crew-afk/scripts/crew-afk.sh:133`), so crew-afk is not changed.
- **D5** (auto) — The key is `solveFeature.publish`; absent or anything other than `false` means publish.
- **D6** (auto) — The PR argument of `reviewed`/`fix`/`describe` is `local` in no-PR mode (their usage regex accepts it), so the run's files are `pr-local.*` and the subagent prompts in SKILL.md keep their `pr-<n>` shape.
- **D7** (auto) — In no-PR mode a PR "exists" when the branch's local body file exists: `land` creates it where it would run `gh pr create` (with the same begin/slug/end markers), `start` and `land` print `pr=local` once it exists (`pr=` empty before), `nothing_left` checks it in place of `pr_view`, and `start`'s cleanup does not delete it, so notes survive a stop and re-run in the same checkout.
- **D8** (auto) — `fix` takes the round's previous head from `.coding-crew/solve-feature/review.base` in place of `gh pr view --json headRefOid` (`:403`); `describe` skips the review-thread count (`unresolved_threads`, `:452`) and `gh pr ready` (`:502`); `start` skips `gh pr ready --undo` (`:164`). The fix commit message drops `PR #`.
- **D9** (auto) — SKILL.md's write-pr prompt names the current branch instead of `PR #<n>` when there is no PR; write-pr already defaults to the current branch (`skills/write-pr/SKILL.md:20`).
- **D10** (auto) — With the github tracker, landed issues stay labelled `awaiting-merge` (`mark-done` only labels, `lib/tracker/docs/github.md:42`); the `Closes #n` lines `describe` writes into the local body file close them once the user opens their own PR. Nothing changes in the tracker.

#### Out of Scope

- An environment-variable override (like `CREW_CODER_MODEL`) — no caller needs it.
- Reading `solveFeature.publish` from the project's config — an Actions run would lose its work with the runner (D2).
- A guard refusing no-PR mode on Actions — moot once the setting is user-level only.
- `address-pr-comments` and the Actions host — no PR exists for them to act on.
- Dropping the `gh` PATH requirement (`solve-feature.sh:42`) — the requester has GitHub; cheap to drop later.

#### Implements

D1–D10, verified at the `solve-feature.sh` CLI seam in the bats suite (`tests/helpers/solve-feature.bash`: bare `origin`, temp `HOME`, stub `gh` logging to `$STATE/gh.log`).

#### Acceptance criteria

- With `{"solveFeature":{"publish":false}}` in `$HOME/.coding-crew/config.json`, a full run (`start` → `next`/`land` → `sync` → `reviewed`/`fix` → `describe`) leaves origin's bare repo without the branch (or with its ref unmoved), and `gh.log` holds no `pr create`, `pr view`, `pr edit`, `pr ready` or `api graphql` call — because every push and every PR-body gh call goes through the publish check.
- The same key in the project's `.coding-crew/config.json` (and none in `$HOME`) has no effect: the run pushes and opens a draft PR as today.
- In no-PR mode `start` prints `pr=` empty before the first land and `pr=local` once the branch's `local-pr-<branch>.md` exists; `land` prints `pr=local`; `start` does not delete it; a `pr-body.md` left by a publish-mode run, or another branch's local file, does not count as this branch's PR.
- `reviewed`, `fix` and `describe` accept `local` as their PR argument and read/write `pr-local.*` files.
- A coder's or fixer's notes file is added to the local body file's notes section exactly as `post_notes` adds it to a PR body today (same `### <tag>` block, same section markers), and the notes file is deleted afterwards.
- `describe` in no-PR mode writes the local body file: a `# <title>` first line (write-pr's title, else `land`'s), then the whole body (write-pr summary, Needs attention, the notes section as the file now holds it — a note a person deleted stays deleted — the spec line, the `Closes` lines, the slug/end markers) and writes the outcome `ready branch=<b>` or `needs-attention branch=<b>`.
- In no-PR mode `sync` on a branch origin lacks merges the default branch in without failing, and runs the checks only when that merge moved HEAD.
- In no-PR mode a checks failure at `land` stops with a message that does not say the work was pushed.
- In no-PR mode `fix` reports `review-again`/`the fixer changed nothing` from the head saved in `review.base`, with no `gh pr view` call.
- In no-PR mode `next` with no ready issue and no local body file for the branch stops with `nothing landed`; with it present it exits 3 printing `reviewer-model=`.
- `skills/solve-feature/SKILL.md`: the settings table has a `solveFeature.publish` row stating it is read from the user-level config only and what it skips; step 3 covers `pr=local` and the `ready|needs-attention branch=<b>` outcome; the write-pr prompt names the branch when there is no PR.

#### Blocked by

None - can start immediately.
