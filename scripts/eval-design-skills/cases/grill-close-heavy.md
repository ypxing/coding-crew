---
skill: crew-grill
stage: close
repo_ref: 9113947
---
## Request
Automatically fix merge conflicts between PRs of different milestones (feature branches vs main).

## Transcript
=== TRANSCRIPT OF PHASE 1 SO FAR (rounds already completed) ===
Facts established:
- Conflicting PRs observed: PR #99 (crew-afk-maintenance) is the only open conflicting PR; its conflicts are exactly registry.json and CHANGELOG.md. Four past main->feature merges (81cc1af, e579fac, fb18ef8, 50f0bba) were hand-merged, each with a registry.json conflict. Each took a few minutes by hand.
- #99 crew-afk version: base 2.6.0, main 2.7.1, PR 2.6.2. "Higher wins" keeps 2.7.1 and silently drops #99's changes for users already on 2.7.1, because install.sh --update compares versions only (tests/registry-version-bump.bats:3-6). The same loss happens on a clean merge when both sides bump to the same value; nothing catches it today.
- Users install from main (CHANGELOG.md:3-5). resolve-merge-conflicts.sh (skills/crew-afk/scripts/) already resolves registry.json versions and CHANGELOG.md appends, all-or-nothing.
- ci.yml has no workflow_dispatch trigger; pushes made with GITHUB_TOKEN start no workflow. The repo has no Actions secrets. open-pr.sh:53 does a plain git push and crew-afk never fetches the remote feature branch. Repo owner is a User account (no merge queue).
Round answers (user):
- Q1 scope: this repo only. Q2: branches keep bumping versions; sync re-bumps on collision. Q3: one CHANGELOG.md, both sides kept. Q4: user said "go with your recommendation" = a GitHub Action crew-sync.yml on push to main that syncs conflicting feature/* PRs mechanically, no secrets. Q5: Action skips PRs whose milestone has an in-progress issue.
Auto decisions made so far (Silent/Notify):
- Version rule: if both sides bumped since merge base, main's version + the PR's bump level (#99 -> 2.7.2); checked after every merge, not only on conflict.
- New CI check: any PR changing an entry's shipped files must land above main's version.
- Shared helper scripts/registry-shipped-paths.sh extracted from the bats test.
- scripts/sync-pr-with-main.sh <branch>: merge origin/main, run resolver, re-bump, commit, push (never force).
- scripts/crew-sync.sh selector: list open PRs via gh, pick conflicting/violating same-repo feature/* ones, apply the in-progress skip, call the sync script.
- CI re-run via gh workflow run ci.yml --ref <branch>; add workflow_dispatch to ci.yml; permissions contents/pull-requests/issues/actions write.
- Refusal: abort merge, create and add needs-human label, one PR comment, dedup while the label is present.
- Concurrency group crew-sync, one run at a time.
The frontier is now empty.

## Reference judgement
The user approved the Action (Q4) and the in-progress skip (Q5); its follow-ons (selector, workflow_dispatch re-trigger, needs-human label protocol, concurrency group) exist only because of it. Measured against the problem (a few minutes per hand-merge, a handful so far), the whole Action chain saves little next to the do-least option (the CI check + re-bump + hand-run sync script, which also fix the silent version loss). Good: show that chain with its total price and the smaller alternative, keeping it by default since the user chose it. Must keep: the version invariant check, the re-bump rule, the shared shipped-paths helper. False cut: dropping the re-bump for unbumped PRs on the claim that the existing test catches them — it compares against the last tag, not main.
