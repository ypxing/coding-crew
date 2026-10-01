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
- Q1 scope: this repo only. Q2: branches keep bumping versions; sync re-bumps on collision. Q3: one CHANGELOG.md, both sides kept. Q4: user chose the do-least option: no automation; a script the maintainer runs by hand, plus a CI check.
Auto decisions made so far (Silent/Notify):
- Version rule: if both sides bumped since merge base, main's version + the PR's bump level (#99 -> 2.7.2); checked after every merge, not only on conflict.
- New CI check in tests/registry-version-bump.bats: any PR changing an entry's shipped files must land above main's version; ci.yml checkout gets fetch-depth: 0.
- Shared helper scripts/registry-shipped-paths.sh extracted from the bats test, used by the check and the sync script.
- scripts/sync-pr-with-main.sh <branch>: merge origin/main, run resolve-merge-conflicts.sh, re-bump, jq-validate, commit; never pushes; on a non-mechanical conflict stops with the merge left for the maintainer.
The frontier is now empty.

## Reference judgement
Lean design the user chose. Every piece is justified: the CI check (silent version loss), the re-bump (#99 → 2.7.2), the shared helper (one owner, no duplicated path logic between the check and the sync script), the hand-run script (replaces the hand merge). Underbuilt: cutting any of these. Overbuilt: adding automation, a selector or labels back. Never-proposed alternatives belong in Out of Scope, not on a cut list (minor).
