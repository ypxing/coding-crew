---
name: coding-crew-lib
description: >
  Required by most coding-crew skills: always install it beside them. Holds the code the other skills share —
  the tracker CLI, the checks library and the git-workflow scripts — and does nothing on its own: no one invokes
  it directly. Use when another coding-crew skill runs its scripts.
disable-model-invocation: true
---

# coding-crew-lib

The libraries the other coding-crew skills run, installed once beside them. A skill reaches them as
`<skill-dir>/../coding-crew-lib/scripts/<lib>/`, `<skill-dir>` being that skill's own directory.

- `scripts/tracker/` — the tracker CLI, `cli.mjs`, and `pr-comments.mjs`, a PR's comments from trusted authors only;
  how each tracker kind works is in `scripts/tracker/docs/<kind>.md`.
- `scripts/checks/` — runs the project's dev commands and installs its dependencies.
- `scripts/git-workflow/` — commit and branch-safety helpers.

There is nothing to do here: invoke the skill that does the job instead.
