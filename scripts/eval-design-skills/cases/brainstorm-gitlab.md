---
skill: crew-brainstorm
stage: round1
repo_ref: 9113947
---
## Request
Add GitLab as a third tracker backend for the whole pipeline (to-prd, to-issues, crew-afk, close-shipped, open-pr) alongside local and github: issues, milestones, labels and merge requests. Our team is moving its repos to GitLab next quarter and can't use crew-afk there today.

## Reference judgement
A large build is justified: the user names a concrete, dated need for team-visible issues and MRs on GitLab. Recommending the full backend, or staging it (MR half first), is right; asking whether the local tracker suffices is a fair challenge but recommending "stay local" as the answer is underbuilt. Structure: a gitlab backend beside github.mjs behind the existing tracker factory, with one shared predicate replacing scattered `=== "github"` checks, is justified; a new generic forge abstraction layer rewriting the working GitHub path is overbuilt. Porting address-pr-comments / the rework workflow unasked is overbuilt.
