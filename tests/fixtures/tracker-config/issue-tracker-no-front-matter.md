# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`.

## Tracker config (optional front matter)

This file may open with YAML front matter declaring which tracker backend the whole
pipeline should use:

```yaml
---
tracker: local          # or "github"
# repo: owner/name      # optional override — omit to let `gh` infer it from the git remote
---
```

Omitting the front matter entirely — as this template does — means `tracker: local` with no
`repo`. `tracker/tracker-config.mjs`'s `readTrackerConfig(mainRoot)` is the one reader of this
front matter (`cli.mjs config` prints its answer); it defaults to `{tracker: "local", repo: null}` when it, or this whole file, is absent,
so existing local-tracker installs need no changes.

## Tracker CLI

Skills and crew-afk read and write this tracker only through the tracker CLI. To run an op by
hand, from the repo root (needs Node):

```bash
TRACKER="$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs"
[ -f "$TRACKER" ] || TRACKER="$HOME/.coding-crew/tracker/cli.mjs"   # user-level install
```

```bash
node "$TRACKER" fetch <ref> [--comments]                  # print one issue; <ref> is its path under .scratch/
node "$TRACKER" prd --feature-slug <slug>                 # print the feature's PRD.md
node "$TRACKER" known --feature-slug <slug> --out <dir>   # copy the feature's issues, open and done, into <dir>
node "$TRACKER" publish-issues --feature-slug <slug> --drafts <dir> [--replace]
node "$TRACKER" publish-prd --feature-slug <slug> --title "<feature title>" --body-file <file>
node "$TRACKER" rewrite <ref> --body-file <file> --status <status> --feature-slug <slug>
node "$TRACKER" mark-done <ref> [--force]
```

Exit codes, every op: `0` ok, `1` the op failed (stderr says why), `2` a usage error or a ref
outside `.scratch/`, `3` not found.

`publish-issues` writes each draft to `.scratch/<slug>/issues/open/<NN>-<slug>.md` (numbered from
`01`) and the drafts' `deps.json` to `.scratch/<slug>/issues/issues-deps.json` — a flat filename
→ blocker-filenames map. That file, not each issue's `## Blocked by` prose, is what the
orchestrator reads to decide whether an issue is ready to dispatch. It exits `4` when the feature
already has issues in `done/` and `5` when it has open ones and `--replace` is absent; both write
nothing. `publish-prd` writes `.scratch/<slug>/PRD.md`.

`mark-done` does not evaluate criteria for you — it only checks that you already did. Before
running it, verify every `- [ ]` in `## Acceptance criteria` (and `## Cross-cutting Requirements`,
if present) against the implemented code and check off the ones the code satisfies. It then
refuses the close in two cases, and both refusals are correct:

| Exit | Meaning                                                                    | What to do                                                                                                                          |
| ---- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `3`  | An orchestrator owns this close (`.scratch/<slug>/.orchestrated` exists, or `CREW_ORCHESTRATED=1`) | Nothing. Report your status and stop — the orchestrator closes the issue after its own verification, criteria and review gates pass. |
| `4`  | Criteria are still unchecked                                               | Do not move the file. Add a `## Unmet criteria` section saying what is missing and why (descoped, blocked, split out), then stop.     |

Pass `--force` only to override a stale marker left by a crashed sprint, or a criterion
deliberately recorded as descoped. On success it sets `Status: done` and moves the file to
`issues/done/` (sibling of `issues/open/`); an issue already in `done/` exits 0.

`done` means implemented and merged into the feature branch, not shipped — for this tracker
there is no later state: nothing outside `.scratch/` reads it, so no PR has anything to close.

An issue may carry a `## Requires` section: one backticked shell command per bullet, naming what its checks need that the project's install does not guarantee (`- \`test -n "$LOCALSTACK_AUTH_TOKEN"\``). Exit 0 means satisfied. Each runs on the host from the project root — once per run, before the issue's first dispatch, under crew-afk; in `solve-issue`'s preflight on a direct run — and a failing one blocks the issue.

## Labels` below.

## Labels

The agents speak in terms of six canonical triage labels, each the `Status:` line's value as written. The strings are fixed: the tracker CLI and crew-afk match them exactly.

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
