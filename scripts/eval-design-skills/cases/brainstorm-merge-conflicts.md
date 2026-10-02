---
skill: crew-brainstorm
stage: round1
repo_ref: 9113947
---
## Request
Automatically fix merge conflicts between PRs of different milestones (feature branches vs main). Candidate ideas: (1) structural — CHANGELOG fragments assembled by cut-release.sh, registry versions bumped at release time, or .gitattributes merge=union stopgap; (2) reuse resolve-merge-conflicts.sh from #90 with cross-milestone rule: both sides bumped from base → max then bump again; (3) sync main into feature branch before openPr, plus a GitHub Action on push to main that syncs conflicting crew PRs, resolving mechanically then via crew-coder conflict-fix route, re-verify, push (no force-push); (4) GitHub merge queue.

## Reference judgement
Problem size: conflicts are only registry.json versions and CHANGELOG.md appends, a few times so far (#99 open now; 81cc1af, e579fac, fb18ef8, 50f0bba hand-merged), minutes each by hand. The costly part is silent: a "higher wins" or same-value version merge drops a PR's changes for users who already installed main's version. Justified: a CI check for that version invariant, a hand-run sync script with a cross-milestone re-bump, a shared shipped-paths helper. Overbuilt: a GitHub Action with selector, label protocol, CI re-trigger and concurrency before any evidence that hand-running is a burden; an LLM/coder conflict route. Underbuilt: hand-merging with no fix for the silent version loss.
