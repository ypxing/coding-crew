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

## Operation: mark-done

Before moving, verify all acceptance criteria in the issue file are satisfied:

1. Check each `- [ ]` criterion against the implemented code.
2. If all are met, check them off (`- [x]`) and update `Status: done`, then move the file to `issues/done/` (sibling of `issues/open/`):
   ```bash
   sed -i'' "s/^Status:.*/Status: done/" "<issue-path>"
   mkdir -p "$(dirname "<issue-path>")/../done"
   mv "<issue-path>" "$(dirname "<issue-path>")/../done/"
   ```
3. If any are unmet, do NOT move the file. Instead, add a `## Unmet criteria` section explaining what's missing and why (descoped, blocked, moved to a new issue), and ask the user how to proceed.

## Operation: status-update

Update the `Status:` line in an issue file:

```bash
sed -i'' "s/^Status:.*/Status: <new-status>/" "<issue-path>"
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
    ├── open/                 ← active issues
    │   ├── 01-<slug>.md      ← implementation issues, numbered from 01
    │   └── 02-<slug>.md
    └── done/                 ← completed issues moved here (sibling of open/)
        └── 01-<slug>.md
```

Comments and conversation history append to the bottom of each issue file under a `## Comments` heading.
