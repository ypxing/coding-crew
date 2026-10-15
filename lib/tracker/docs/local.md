# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`.

## Tracker config

The tracker this repo uses is the `tracker` section of `.coding-crew/config.json`:

```json
{ "tracker": { "kind": "local" } }
```

`kind` is `local` or `github`; other sections of the file (`solveFeature`) are kept beside it. No
`tracker` section means `local`, so this tracker needs no config at all. `configure-tracker`
writes the section, and `node "$TRACKER" config` prints what is in effect (`tracker=<kind>`,
`configured=yes|no`). This doc ships with the tracker CLI in `.coding-crew/lib/tracker/docs/` and is
refreshed by every install — edit `config.json`, not this file.

## Tracker CLI

Skills read and write this tracker only through the tracker CLI. To run an op by
hand, from the repo root (needs Node):

```bash
TRACKER="$HOME/.coding-crew/lib/tracker/cli.mjs"   # a project-level install: .coding-crew/lib/tracker/cli.mjs
```

```bash
node "$TRACKER" fetch <ref> [--comments]                  # print one issue; <ref> is its path under .scratch/
node "$TRACKER" features                                  # list the features: <slug>, open|closed, count of issues that can start now
node "$TRACKER" prd --feature-slug <slug>                 # print the feature's PRD.md
node "$TRACKER" next --feature-slug <slug>                # the absolute path of the next issue to run, or exit 3
node "$TRACKER" closing-refs --feature-slug <slug>        # prints nothing: a local issue has no PR to close it
node "$TRACKER" known --feature-slug <slug> --out <dir>   # copy the feature's issues, open and done, into <dir>
node "$TRACKER" publish-issues --feature-slug <slug> --drafts <dir> [--replace]
node "$TRACKER" publish-prd --feature-slug <slug> --title "<feature title>" --body-file <file>
node "$TRACKER" rewrite <ref> --body-file <file> --status <status> --feature-slug <slug>
node "$TRACKER" tick <ref>                                # check every criterion off
node "$TRACKER" write-section <ref> --heading <h> --body-file <file>   # write `## <h>` into the issue file
node "$TRACKER" mark-done <ref> [--force]
node "$TRACKER" reopen <ref>                              # undo mark-done: ready-for-agent again
```

Exit codes, every op: `0` ok, `1` the op failed (stderr says why), `2` a usage error or a ref
outside `.scratch/`, `3` not found.

`next` prints the path of the first open file, in filename order, whose `Status:` is
`ready-for-agent` and whose every `## Blocked by` file (or `issues-deps.json` entry) sits in the
feature's `done/`; it prints nothing and exits `3` when there is none.

`features` prints one tab-separated line per `.scratch/<slug>/` directory that has an `issues/`
subdirectory, sorted by slug: `<slug>`, `open` (`issues/open/` holds an `.md` file) or `closed`, and
the count of issues that can start now: `Status: ready-for-agent` files in `issues/open/` whose
every blocker (from `issues-deps.json` when the feature has one, else `## Blocked by`) is in the
feature's `issues/done/`, as `next` reads them. A directory without `issues/` is
not listed, and no `.scratch/` prints nothing.

`publish-issues` writes each draft to `.scratch/<slug>/issues/open/<NN>-<slug>.md` (numbered from
`01`) and the drafts' `deps.json` to `.scratch/<slug>/issues/issues-deps.json` — a flat filename
→ blocker-filenames map. That file, not each issue's `## Blocked by` prose, is what `next` and
`features` read to decide whether an issue can start. It exits `4` when the feature
already has issues in `done/` and `5` when it has open ones and `--replace` is absent; both write
nothing. `publish-prd` writes `.scratch/<slug>/PRD.md`.

`mark-done` does not evaluate criteria for you — it only checks that you already did. Before
running it, verify every `- [ ]` in `## Acceptance criteria` (and `## Cross-cutting Requirements`,
if present) against the implemented code; once all of them hold, `tick <ref>` checks them off in
one write (it prints `TICKED: <file> — <n> criteria`; a body with no criteria section ticks
nothing). `write-section <ref> --heading <h> --body-file <file>` replaces, or appends, the `## <h>`
section of the file: how `## Unmet criteria` is recorded. `mark-done` then refuses the close with
exit `4` while criteria are still unchecked: do not move the file; add a `## Unmet criteria` section
saying what is missing and why (descoped, blocked, split out), then stop. It also exits `4` for an
issue with no `## Acceptance criteria` section at all, unless `--force`.

Pass `--force` only for a criterion deliberately recorded as descoped. On success it sets `Status: done` and moves the file to
`issues/done/` (sibling of `issues/open/`); an issue already in `done/` exits 0.

`done` means implemented and merged into the feature branch, not shipped — for this tracker
there is no later state: nothing outside `.scratch/` reads it, so no PR has anything to close.

An issue may carry a `## Requires` section: one backticked shell command per bullet, naming what its checks need that the project's install does not guarantee (`- \`test -n "$LOCALSTACK_AUTH_TOKEN"\``). Exit 0 means satisfied. Each runs on the host from the project root, in `solve-issue`'s preflight, and a failing one blocks the issue.

## Reopen an issue

To undo `mark-done` and hand the issue to an agent again, `node "$TRACKER" reopen <ref>` (its `open/` or
`done/` path): it moves the file back to `issues/open/` with `Status: ready-for-agent`, and leaves its
ticked criteria ticked. solve-feature runs it when an issue's checks fail after its coder closed it.

To put a finished issue in a human's hands instead:

1. Move the file from `.scratch/<slug>/issues/done/` back to `.scratch/<slug>/issues/open/`.
2. Set its `Status:` line to `ready-for-human`.

## Labels

The agents speak in terms of six canonical triage labels, each the `Status:` line's value as written. The strings are fixed: the tracker CLI matches them exactly.

| Canonical label   | `Status:` value   | Meaning                                                                              |
| ----------------- | ----------------- | ------------------------------------------------------------------------------------ |
| `needs-triage`    | `needs-triage`    | Maintainer needs to evaluate this issue                                              |
| `needs-info`      | `needs-info`      | Waiting on reporter for more information                                             |
| `ready-for-agent` | `ready-for-agent` | Fully specified, ready for an AFK agent                                              |
| `ready-for-human` | `ready-for-human` | Requires human implementation                                                        |
| `wontfix`         | `wontfix`         | Will not be actioned                                                                 |
| `done`            | `done`            | Issue is complete and closed (set by agents on completion, not a human triage label) |

## Workspace

Each feature slug maps to a directory under `.scratch/`:

```
.scratch/<feature-slug>/
├── PRD.md                    ← optional product requirements doc
└── issues/
    ├── issues-deps.json      ← optional; filename → blocker-filenames map (written by publish-issues)
    ├── open/                 ← active issues
    │   ├── 01-<slug>.md      ← implementation issues, numbered from 01
    │   └── 02-<slug>.md
    └── done/                 ← completed issues moved here (sibling of open/)
        └── 01-<slug>.md
```

Comments and conversation history append to the bottom of each issue file under a `## Comments` heading.
