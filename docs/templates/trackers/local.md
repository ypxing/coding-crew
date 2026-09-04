# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`.

## Operation: list

Find all open issues ready for an agent:

```bash
grep -rl "Status: ready-for-agent" .scratch/*/issues/open/*.md 2>/dev/null
```

## Operation: fetch

Read one issue file by path. The caller normally passes the path directly:

```bash
cat .scratch/<feature-slug>/issues/open/<NN>-<slug>.md
```

## Operation: publish

Create a new issue or PRD file under `.scratch/`:

- PRD: `.scratch/<feature-slug>/PRD.md`
- Issue: `.scratch/<feature-slug>/issues/open/<NN>-<slug>.md` (numbered from `01`)

Create the directory if it does not exist. Set a `Status:` line near the top of the file.

When issues come from `to-issues`, it also writes `.scratch/<feature-slug>/issues/issues-deps.json` — a flat filename → blocker-filenames map. That file, not each issue's `## Blocked by` prose, is what the orchestrator reads to decide whether an issue is ready to dispatch.

## Operation: mark-done

Delegate to the tracker's close script — do not hand-run `sed` or `mv`:

```bash
bash "$(git rev-parse --show-toplevel)/.coding-crew/scripts/mark-issue-done.sh" "<issue-path>"
```

The script does not evaluate criteria for you — it only checks that you already did. Before
calling it, verify every `- [ ]` in `## Acceptance criteria` (and `## Cross-cutting Requirements`,
if present) against the implemented code and check off the ones the code satisfies.

The script then refuses the close in two cases, and both refusals are correct:

| Exit | Meaning                                                                    | What to do                                                                                                                          |
| ---- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `3`  | An orchestrator owns this close (`.scratch/<slug>/.orchestrated` exists, or `CREW_ORCHESTRATED=1`) | Nothing. Report your status and stop — the orchestrator closes the issue after its own verification, criteria and review gates pass. |
| `4`  | Criteria are still unchecked                                               | Do not move the file. Add a `## Unmet criteria` section saying what is missing and why (descoped, blocked, split out), then stop.     |

Pass `--force` only to override a stale marker left by a crashed sprint, or a criterion
deliberately recorded as descoped.

On success the script sets `Status: done` and moves the file to `issues/done/` (sibling of
`issues/open/`). It is idempotent: an issue already in `done/` exits 0.

## Operation: status-update

Update the `Status:` line in an issue file:

```bash
sed "s/^Status:.*/Status: <new-status>/" "<issue-path>" > "<issue-path>.tmp" \
  && mv "<issue-path>.tmp" "<issue-path>"
```

Valid status strings are listed in `## Labels` below.

## Labels

The agents speak in terms of six canonical triage labels. This section maps those labels to the actual strings used in this repo's issue tracker.

| Canonical label   | Default string    | Meaning                                                                              |
| ----------------- | ----------------- | ------------------------------------------------------------------------------------ |
| `needs-triage`    | `needs-triage`    | Maintainer needs to evaluate this issue                                              |
| `needs-info`      | `needs-info`      | Waiting on reporter for more information                                             |
| `ready-for-agent` | `ready-for-agent` | Fully specified, ready for an AFK agent                                              |
| `ready-for-human` | `ready-for-human` | Requires human implementation                                                        |
| `wontfix`         | `wontfix`         | Will not be actioned                                                                 |
| `done`            | `done`            | Issue is complete and closed (set by agents on completion, not a human triage label) |

Edit the right-hand column to match whatever vocabulary your project actually uses.

## Workspace

Each feature slug maps to a directory under `.scratch/`:

```
.scratch/<feature-slug>/
├── PRD.md                    ← optional product requirements doc
└── issues/
    ├── issues-deps.json      ← optional; filename → blocker-filenames map (written by to-issues)
    ├── open/                 ← active issues
    │   ├── 01-<slug>.md      ← implementation issues, numbered from 01
    │   └── 02-<slug>.md
    └── done/                 ← completed issues moved here (sibling of open/)
        └── 01-<slug>.md
```

Comments and conversation history append to the bottom of each issue file under a `## Comments` heading.
