# Issue tracker: GitHub Issues

Issues, PRDs, and features live as GitHub Issues: a feature is one root issue and its sub-issues
(see [Workspace](#workspace)). Requires the `gh` CLI (2.102 or later, for `--parent`),
authenticated (`gh auth status`), on every machine that runs a tracker-touching skill or script.

## Tracker config

The tracker this repo uses is the `tracker` section of `.coding-crew/config.json`, else `~/.coding-crew/config.json`'s:

```json
{ "tracker": { "kind": "github" } }
```

`configure-tracker` writes it when you choose `github` (other sections of the file are kept), and
`node "$TRACKER" config` prints what is in effect. `gh` targets the repo of the current
directory's git remote; there is no override. This doc ships beside the tracker CLI in the `coding-crew-lib`
skill (`coding-crew-lib/scripts/tracker/docs/`, copied through its link into `lib/`) and is refreshed by every install — edit
`config.json`, not this file.

## Tracker CLI

Skills read and write this tracker only through the tracker CLI, which runs `gh`
for them. To run an op by hand, from the repo root (needs Node and an authenticated `gh`):

```bash
TRACKER="<skills-dir>/coding-crew-lib/scripts/tracker/cli.mjs"   # e.g. ~/.claude/skills/…, or .agents/skills/… in the repo
```

```bash
node "$TRACKER" fetch <number> [--comments]               # print one issue (title, body; + comments by users with write access or bots in github.trustedBots, on a private or internal repo)
node "$TRACKER" status <number>                           # its status: done, wontfix, a triage status, or empty
node "$TRACKER" features                                  # list the features: <slug>, open|closed, count of issues that can start now
node "$TRACKER" prd --feature-slug <slug>                 # print the feature's PRD: issue
node "$TRACKER" next --feature-slug <slug>                # the number of the next issue to run, or exit 3
node "$TRACKER" known --feature-slug <slug> --out <dir>   # write the feature's issues, open and closed (not wontfix), into <dir>
node "$TRACKER" spec --feature-slug <slug>                # print the feature's spec: the PRD, then each issue `known` writes, whole
node "$TRACKER" publish-issues --feature-slug <slug> --drafts <dir> [--replace | --append]
node "$TRACKER" publish-prd --feature-slug <slug> --title "<feature title>" --body-file <file>
node "$TRACKER" rewrite <number> --body-file <file> --status <status> --feature-slug <slug>
node "$TRACKER" tick <number>                             # check every criterion off, in the live body
node "$TRACKER" write-section <number> --heading <h> --body-file <file>   # a `## <h>` comment on the issue
node "$TRACKER" mark-done <number> [--force]
node "$TRACKER" reopen <number>                           # undo mark-done: ready-for-agent again
node "$TRACKER" closing-refs --feature-slug <slug>       # the feature PR's `Closes #n` lines
```

Exit codes, every op: `0` ok, `1` the op failed (stderr carries `gh`'s own error, verbatim), `2` a
usage error or a ref that is not an issue number, `3` not found.

`next` prints the lowest-numbered open issue of the feature (the root included) labelled
`ready-for-agent`, not labelled `blocked`, whose every `## Blocked by` issue is closed or
`awaiting-merge`; it prints nothing and exits `3` when there is none. A blocker outside the feature
is read by number and resolves the same way; one open, missing or deleted holds the issue back.

A `gh` call that fails on the network or GitHub's side — `EOF`, a connection reset or refused, a
DNS failure, a timeout, an `HTTP 5xx`, a secondary rate limit — is retried up to 3 times, after
1s, 2s and 4s (a warning line on stderr each time); past that the op fails with the last `gh`
error. Every other failure (auth, not found, a usage error) fails at once. A call that creates
something (`issue create`, `issue comment`, a `gh api` POST) is retried only when it failed
before the request was sent (a connection refused, DNS or TLS-handshake failure), so a retry
never files a duplicate.

`features` prints one tab-separated line per root issue's slug, sorted: the slug, `open` while the
root or any of its sub-issues is open (`closed` otherwise) and the count of issues among the root
and its sub-issues that can start now: open, `ready-for-agent`, no `blocked` label, and every
`## Blocked by` issue closed or `awaiting-merge`, as `next` does. A slug on more than one root is
listed once, with a warning on stderr, its roots' issues counted as one feature. A closed root whose sub-issues have all closed is listed from its
`sub_issues_summary` without reading them. A failing `gh` exits `1` with `gh`'s stderr verbatim.

`publish-issues`, `publish-prd` and `rewrite` file their issues in the feature: the first issue
filed for a slug with no root becomes its root (the CLI adds the `Feature:` line), and every later
one is created as a sub-issue of that root (`gh issue create --parent <root>`). A closed root is
never reopened; new issues are filed under it as it is. `publish-issues` creates one issue per
draft, labelled by its `Status:` line, in dependency order, rewriting each draft's `## Blocked by`
to `Issue #<n>` with the number its blocker got and mirroring those edges as native GitHub
dependencies (best-effort: a failed link only warns; `next` reads the body's `## Blocked by`).
A feature's issues only accumulate, so it never exits `4` or `5`, and `--append` changes nothing. `publish-prd` creates the
`PRD: <feature title>` issue — as the root when the slug has none, else as a sub-issue of the
root — or edits the feature's existing one, keeping its `Feature:` line. It pins nothing: the
root's sub-issue progress bar is the feature's overview. Work issues cite it as `PRD: #<n>`.
`rewrite` replaces a single-slice source issue's body, sets `<status>` as its only triage label
(it replaces any other triage label the issue carries: `needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`) and files it in the feature: as its root when the slug has
none (the `Feature:` line added, and kept on every later rewrite of the root), else under the
root with `gh issue edit --parent`. It exits `1`, editing nothing, when the issue is already a
sub-issue of another issue or carries another slug's `Feature:` line: it never moves an issue out
of another feature. One exception: an issue that becomes the root keeps a parent with no
`Feature:` line (a human's epic, say), since making it the root moves nothing.

`closing-refs` prints the `Closes #<n>` lines the feature's PR body needs, one per line, by the
rule below: every open `awaiting-merge` issue of the feature, plus its `PRD:` issue (and that
PRD's `Origin:` issues) once no open work issue is left. It prints nothing when nothing ships.

Every op that reads a feature exits `1` naming them when its slug is ambiguous: two open issues
carrying the same `Feature:` line, or none open and two or more closed. Remove the line from all
but one of them.

`done` means implemented and merged into the feature branch, not shipped. An issue's body has no
file to edit, so `tick <number>` is how criteria are checked off: it fetches the body live, turns
every `- [ ]` under `## Acceptance criteria` (or `## Cross-cutting Requirements`) into `- [x]` and
writes it back with `gh issue edit`, printing `TICKED: issue #<n> — <k> criteria`; run it only once
every criterion holds. `write-section <number> --heading <h> --body-file <file>` posts the file as
a comment headed `## <h>` — never a body edit — which is how `## Unmet criteria` is recorded here.
`mark-done` re-fetches the body live and refuses with exit `4` while an `- [ ]` in
`## Acceptance criteria` (or `## Cross-cutting Requirements`) is unchecked — report your status
and stop. It also exits `4` for a
body with no `## Acceptance criteria` section at all, unless `--force`. Never close the issue by
hand instead.

On success `mark-done` swaps `ready-for-agent` for `awaiting-merge` (creating that label if the repo
lacks it) and leaves the issue **open**. Put `Closes #<number>` in the body of the PR that
carries the work: GitHub closes the issue when that PR merges into the default branch.
solve-feature writes these lines (`closing-refs`) into its PR's body. (A PR into any other branch
does not trigger the keyword — close those by hand.)

## Reopen an issue

To undo `mark-done` and hand the issue to an agent again, `node "$TRACKER" reopen <number>`: it swaps
`awaiting-merge` for `ready-for-agent`, reopening an issue its merged PR already closed first, and leaves
its ticked criteria ticked. solve-feature runs it when an issue's checks fail after its coder closed it.

To put a finished issue in a human's hands instead, swap the labels yourself (`gh issue reopen <number>`
first if it is closed):

```bash
gh issue edit <number> --remove-label awaiting-merge --add-label ready-for-human
```

## Labels

The agents speak in terms of six canonical triage labels. Five are real GitHub labels; `wontfix`
maps to a close-reason.

| Canonical label   | GitHub representation                                    | Meaning                                  |
| ----------------- | --------------------------------------------------------- | ----------------------------------------- |
| `needs-triage`    | label `needs-triage`                                       | Maintainer needs to evaluate this issue   |
| `needs-info`      | label `needs-info`                                         | Waiting on reporter for more information  |
| `ready-for-agent` | label `ready-for-agent`                                     | Fully specified, ready for an AFK agent   |
| `ready-for-human` | label `ready-for-human`                                     | Requires human implementation             |
| `done`            | label `awaiting-merge` while open; closed (`completed`) once its PR merges | Implemented; shipped once closed |
| `wontfix`         | close-reason `not-planned` (`gh issue close --reason not-planned`) — **not a label** | Will not be actioned |

`done` has two representations on purpose: "merged into the feature branch" and "shipped" are
different facts, and only a PR merge establishes the second. Closing at the first would show
issues as completed on GitHub while their code exists only in a local branch. Both read as
`done` for `next` and for `## Blocked by` resolution; a `wontfix` blocker resolves too, but `known`
leaves a `wontfix` issue out. `gh issue create --label x` and `gh issue edit
--add-label x` fail outright if `x` isn't already a repo label, so the tracker creates all six status labels
(including `blocked` and `needs-info`, which a person picks in GitHub's UI) with `gh label create <name> --color <fixed colour>` (no `--force`: a label that already exists, and the colour a team gave it, is left as it is),
once per CLI invocation, before the first call that applies one: `publish-issues`, `rewrite`, `mark-done` and
`reopen`.

Statuses other than `done` are labels a person sets in GitHub; `wontfix` closes the issue with a
reason instead of setting a label:

```bash
gh issue close <number> --reason not-planned   # wontfix
```

## Blocked issues

A person adds the `blocked` label **next to** `ready-for-agent` to an issue that needs a human.
`next` and `features` skip an issue labelled `blocked`, and issues whose `## Blocked by` names it
keep waiting — `blocked` is not `done`. To put it back in the queue once its cause is fixed:

```bash
gh issue edit <number> --remove-label blocked
```

## Workspace

A feature is one **root issue** and its native **sub-issues**, one level deep. The root is the
feature's `PRD:` issue, or for a single-slice feature the work issue itself; its body carries a
column-0 line naming the feature slug:

```
Feature: <slug>
```

The tracker CLI writes that line (on the issue it creates as a root, and on every rewrite or
re-publish of it) — never a skill — and finds a feature by it, scanning the repo's
issues through the REST list API (open ones first, then all), paginated. That list lags a new
issue by a few seconds, so when it shows no open root the issues numbered past its newest are read
one by one: `publish-issues` right after `publish-prd` finds the root just created. It scans once
per process: later reads re-read the root it
found, and scan again only once that issue is gone or no longer carries the line. Every slice is a
sub-issue of the root (`--parent <root>`).
A feature's issues are the root plus its sub-issues, read from
`repos/{owner}/{repo}/issues/<root>/sub_issues`, paginated, so no page is cut short; a slug with
no root reads as an empty feature. GitHub caps a parent at 100 sub-issues: past that, filing
another issue in the feature fails (`gh issue create --parent` exits non-zero), so close the
feature and start a new slug well before it. The PRD is identified by title convention
(`PRD: <feature title>`), not a local file, whether it is the root or a sub-issue of a work-issue
root. Work issues use the same markdown body conventions as local issues (`## Blocked by`,
`## Acceptance criteria`, `Source:`).

Comments and conversation history append to the issue as ordinary `gh issue comment` timeline
entries.

## Moving off milestones

Earlier versions grouped a feature under a GitHub milestone named for its slug. That is gone, with
no fallback read: after `install.sh --update`, a feature still filed under a milestone is invisible
to every skill (it reads as empty) until you move it by hand. For each feature still in progress:

1. Pick its root — the `PRD:` issue, or for a single-slice feature the work issue — and add the
   slug line to the root's body, on a line of its own at column 0:

   ```
   Feature: <slug>
   ```

2. Make every issue of the milestone a sub-issue of the root — closed ones too, not just open
   ones, so the feature lists all its issues:

   ```bash
   gh issue list --milestone <slug> --state all --limit 1000 --json number -q '.[].number' |
     while read -r n; do [ "$n" = <root> ] || gh issue edit "$n" --parent <root>; done
   ```

3. Close the milestone (on GitHub: Issues → Milestones → Close), so it stops collecting issues.

`node "$TRACKER" known --feature-slug <slug> --out <dir>` then writes every work issue you moved
into `<dir>` (not the `PRD:` issue: `known` leaves it out); `node "$TRACKER" features` lists the
slug; and any op on the slug exits `1` naming both issues if two still carry the `Feature:` line.
