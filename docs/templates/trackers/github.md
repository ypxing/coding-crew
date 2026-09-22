# Issue tracker: GitHub Issues

Issues, PRDs, and features live as GitHub Issues and Milestones. Requires the `gh` CLI,
authenticated (`gh auth status`), on every machine that runs a tracker-touching skill or script.

## Tracker config (optional front matter)

This file opens with YAML front matter declaring which tracker backend the whole pipeline
should use, and (optionally) which repo to target:

```yaml
---
tracker: github         # or "local"
repo: owner/name        # optional override — omit to let `gh` infer it from the git remote
---
```

`configure-tracker` writes this block when you choose `github`. `orchestrator/lib/
tracker-config.mjs`'s `readTrackerConfig(mainRoot)` and `scripts/tracker/tracker-config.sh`'s
`read_tracker_config` are the two readers of this front matter. `repo` is a pure override: `gh`
already infers the repo from the current directory's git remote when `--repo` is omitted, so
leave it out unless issues are tracked in a different repo than the code.

## Operation: list

Find all open issues ready for an agent, scoped to the feature's milestone, in one call
(never a ref-per-issue fetch):

```bash
gh issue list [--repo owner/name] --milestone <feature-slug> --state all \
  --json number,title,body,labels,state --label ready-for-agent
```

`--state all` is deliberate even for "list ready issues": blocker resolution needs to know
whether a referenced issue is already closed, not just which issues are open.

## Operation: fetch

Read one issue by number. The caller normally already has the number from `list`:

```bash
gh issue view <number> [--repo owner/name] --json number,title,body,labels,state
```

## Operation: publish

Create a new issue or PRD issue, both scoped to the feature's milestone (created lazily, on
first write, if it doesn't already exist):

```bash
# Milestone, created only if a list-first check shows it's missing (idempotent):
gh api repos/{owner}/{repo}/milestones -f title=<feature-slug>

# PRD — identified by title convention plus milestone scope, not a label:
gh issue create [--repo owner/name] --title "PRD: <feature title>" \
  --body-file <prd-file> --milestone <feature-slug>
# Best-effort pin — GitHub caps pinned issues at 3/repo, so a pin failure must not fail publish:
gh issue pin <number> [--repo owner/name] || true

# Work issue — the body file must itself contain the same `## Blocked by`/`Source:` prose
# local issues use; that prose is the dependency graph for this backend (no sidecar file):
gh issue create [--repo owner/name] --title "<title>" --body-file <body-file> \
  --label <status> --milestone <feature-slug>
```

Revising the PRD in place: `gh issue edit <n> --body-file <prd-file>`. Work issues cite the PRD
as `PRD: #<n>` in their body.

## Operation: mark-done

Before checking criteria, re-fetch the issue body live — never trust an object the caller holds
from an earlier `list` call, since a human may have edited it since:

```bash
gh issue view <number> [--repo owner/name] --json body --jq .body
```

Verify every `- [ ]` in `## Acceptance criteria` (and `## Cross-cutting Requirements`, if
present) against the implemented code. Only once every box is checked:

```bash
gh issue close <number> [--repo owner/name] --reason completed
```

Closing *is* "done" for this backend — see Labels below for why there is no separate label.

## Operation: status-update

Non-terminal statuses swap the label:

```bash
gh issue edit <number> [--repo owner/name] --add-label <new-status> --remove-label <old-status>
```

Terminal statuses (`done`, `wontfix`) close the issue with a reason instead of setting a label:

```bash
gh issue close <number> [--repo owner/name] --reason completed     # done
gh issue close <number> [--repo owner/name] --reason not-planned   # wontfix
```

## Labels

The agents speak in terms of six canonical triage labels. Only four are real, pre-created
GitHub labels; `done` and `wontfix` map to close-reasons, not labels.

| Canonical label   | GitHub representation                                    | Meaning                                  |
| ----------------- | --------------------------------------------------------- | ----------------------------------------- |
| `needs-triage`    | label `needs-triage`                                       | Maintainer needs to evaluate this issue   |
| `needs-info`      | label `needs-info`                                         | Waiting on reporter for more information  |
| `ready-for-agent` | label `ready-for-agent`                                     | Fully specified, ready for an AFK agent   |
| `ready-for-human` | label `ready-for-human`                                     | Requires human implementation             |
| `done`            | close-reason `completed` (`gh issue close --reason completed`) — **not a label** | Issue is complete and closed |
| `wontfix`         | close-reason `not-planned` (`gh issue close --reason not-planned`) — **not a label** | Will not be actioned |

Representing "done" as both a label and a close-reason would be two representations of one
fact, and `gh issue list` already defaults to open issues, so a closed issue never needs a
label to be excluded from dispatch. `configure-tracker`'s github setup idempotently creates the
four real labels before first publish, since `gh issue create --label x` fails outright if `x`
isn't already a repo label.

## Workspace

A feature maps to a GitHub **Milestone** named for the feature slug. The feature's PRD is an
issue inside that milestone, identified by title convention (`PRD: <feature title>`), not a
local file. Work issues are regular issues in the same milestone, using the same markdown body
conventions as local issues (`## Blocked by`, `## Acceptance criteria`, `Source:`).

No filename exists to derive a slug or branch from, so both are derived deterministically from
the issue every time: kebab-case the title for the slug, and include the issue number in the
branch name for uniqueness: `crew/<featureSlug>/<number>-<slug>`. Nothing to cache — GitHub
issue numbers are stable, unambiguous identifiers, unlike local filenames.

Comments and conversation history append to the issue as ordinary `gh issue comment` timeline
entries — a live activity feed, not an in-place-edited section like local's `## Comments`.
