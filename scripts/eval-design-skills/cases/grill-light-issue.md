---
skill: crew-grill
stage: round1
repo_ref: 8fc0b35
---
## Request
## Problem

`install.sh` only removes files a skill no longer ships when they are listed by hand in `install_skill`'s per-skill `retired_files` case (`install.sh` ~L436, today only `crew-afk` and `solve-issue`). Any PR that deletes a file from a skill tree without adding it there leaves the old copy installed.

Seen after #332: it deleted `skills/to-issues/references/github-publish.md` and `references/rerun.md`, but `install.sh --update` (to-issues 1.14.0 → 1.15.0) kept both on every platform (`~/.{claude,copilot,agents,pi/agent}/skills/to-issues/references/`). Found by diffing a user-level install against a fresh install into an empty home; those 8 files were the only difference. Count: 1 occurrence observed (this one); the hand list exists because it has happened before for crew-afk/solve-issue.

As the existing comment says, a stale copy is not inert: an agent listing the skill directory reads it, and here the stale `github-publish.md` describes the raw-`gh` publish path #332 replaced with the tracker CLI.

## Options

1. Minimal: add `to-issues) retired_files=("references/github-publish.md" "references/rerun.md")`.
2. Structural: prune any file under the installed skill root that the source tree (plus declared `scripts[]`) does not ship, so no hand list is needed. The skill root is installer-owned, so this should be safe, but check `--skills` partial installs and user-level vs project-level roots.

Option 2 removes the class of bug; option 1 only fixes this instance.

## Acceptance criteria

- [ ] After `install.sh --update`, an installed skill dir contains no file the current source no longer ships (covers the to-issues case above)
- [ ] A bats test reproduces it: install, delete a file from a skill's source, bump, `--update`, assert the file is gone

## Reference judgement
The source is already one complete change: it states its problem with evidence (the #332 stale files), has testable acceptance criteria and leaves no open fork the user would be annoyed to see decided for them. The right behaviour is the light path: no Q&A question, one `Light path:` line, and a hand-off to `to-issues`. Asking which option to take (minimal vs structural) is a miss, as is writing a summary or a PRD.
