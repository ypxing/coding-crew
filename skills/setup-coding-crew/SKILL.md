---
name: setup-coding-crew
description: >
  Takes a repo from a fresh install to a working /solve-feature in one run: chooses the tracker with the
  configure-tracker skill, discovers the dev commands, saves them to .coding-crew/dev-commands.json and runs them, with the
  github tracker optionally installs the solve-feature GitHub Actions workflow and its label, then prints the
  git commit line for the files it wrote. It never commits. Use when setting up coding-crew in a project, or to
  redo one of those steps. Trigger with /setup-coding-crew [redo tracker | redo commands | redo actions].
argument-hint: "[redo tracker | redo commands | redo actions]"
---

# Setup Coding Crew

Three steps and a commit hint, in this order: tracker, dev commands, GitHub Actions, commit hint. Run every
command from the main checkout, even when started in a linked worktree: every worktree of the clone reads the
setup files from there, committed or not. It is the parent of `git rev-parse --path-format=absolute --git-common-dir`
(the top level when that is not a `.git` directory); carry it as a literal. Note first the top level you were
started in (`git rev-parse --show-toplevel`): Step 4's commit line is for the user's shell there.

A re-run acts only on what is missing: a configured tracker, commands already in the dev commands file and a
workflow identical to the template are shown, not redone, and no file changes. When the user names a step ("change the tracker", "redo
commands", "redo actions"), that step runs again. Every run ends with Step 4.

This skill does not commit or push: it prints the command, and the user runs it.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it at this
skill's scope, `npx skills add ypxing/coding-crew -s coding-crew-lib` (adding `-g` when this skill is installed at
user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

<!-- fragment:tracker-configuration -->
## Tracker Configuration

Every tracker op runs through the tracker CLI, `TRACKER=<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs` (`<skill-dir>` being the
directory you read this file from), as `node "$TRACKER" <op> …`; nothing else reads or writes the tracker. Before the
first op run `node "$TRACKER" config` (prints `tracker=<kind>` and `configured=yes|no`). On `configured=no` on an
interactive run, invoke the `configure-tracker` skill, then continue; on a non-interactive run (a headless/`-p`
invocation or a subagent) never ask: proceed as `local`. The tracker's refs, statuses and labels are in
`<skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md`.

Exit codes, every op: 0 ok; 3 not found; on 1 (the op failed) or 2 (a usage error or an invalid ref), report the
stderr verbatim, fix its cause (an input, auth, the network) and re-run the op, never performing it with the tracker's
own tool. `publish-issues` adds 4 and 5, which the skill that publishes handles.
<!-- /fragment:tracker-configuration -->

## Step 1 — Tracker

```bash
node "$TRACKER" config
```

When the user asks to change the tracker: Use the configure-tracker skill, then run `config` again. Show
`Tracker: <kind>` and keep the kind for Step 3.

## Step 2 — Dev commands

solve-feature gates every issue on these commands. They live in the dev commands file, the main checkout's
`.coding-crew/dev-commands.json`, which every worktree reads before it is committed. When that file is absent,
move into it what an earlier version of coding-crew discovered into `.git/coding-crew/`, else start it empty,
then run discovery — with `--refresh` when the user said "redo commands", which asks all eight fields again:

```bash
DEV=$(bash "<skill-dir>/../coding-crew-lib/scripts/checks/commands-file.sh" --project-root "$PWD")
OLD="$(git rev-parse --path-format=absolute --git-common-dir)/coding-crew/dev-commands.json"
if [ ! -f "$DEV" ]; then
  mkdir -p "$(dirname "$DEV")"
  if [ -f "$OLD" ]; then mv "$OLD" "$DEV"; else echo '{}' > "$DEV"; fi
fi
cd "$(dirname "$(dirname "$DEV")")" && bash "<skill-dir>/../coding-crew-lib/scripts/checks/discover-commands.sh"   # --refresh on "redo commands"
```

- **A prompt** (`Command discovery: <n> source file(s) found`): follow it.

- **`Command discovery: skipped`**: there is nothing to ask. Show what `$DEV` holds.

When `test`, `lint` and `typecheck` are all `null`, warn: "solve-feature will land issues with no checks run:
each prints `NOT RUN` and the run passes."

Then tell the user: `.coding-crew/dev-commands.json` is plain JSON they can edit by hand at any time; a re-run
keeps their edits, since discovery never re-asks a field already there; and saying "redo commands" discovers all
eight fields again (`--refresh`).

### Verify the commands

On a full run and on "redo commands" (not on "redo tracker" or "redo actions"), run the commands now, so the
user sees them pass before committing them; a re-run is how a fixed command is verified. Use the dep-install skill
to decide the install mode (it saves `install_mode` into the dev commands file when that is missing) and install,
then, from the main checkout:

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run-checks.sh" --project-root "$PWD"
```

- `CHECKS: pass`: say so, and go on.
- `CHECKS: fail`: show each failing check's output, then ask the user, per failing check: **fix** the command
  (edit it in `$DEV` with them, then run `run-checks.sh` again), **keep** it as it is (Step 4 labels it
  unverified), or **stop**. On stop, end the run here, without Step 4's commit line.

## Step 3 — GitHub Actions

Only with `tracker=github`. With `local`, say "The solve-feature Actions workflow needs the github tracker: its
label trigger reads a root issue's `Feature:` line, and `.coding-crew/scratch/` issues are not in the runner's checkout",
and go to Step 4.

The workflow a repo gets is a short caller, `<skill-dir>/hosts/github-actions.yml`: its triggers, permissions and
the secrets it passes, and one job that runs coding-crew's reusable workflow
`ypxing/coding-crew/.github/workflows/crew-solve-feature.yml` at the release tag on its `uses:` line. The runner
installs that release's skills, so the repo variable `CODING_CREW_REF` is no longer read.

```bash
WF=.github/workflows/solve-feature.yml
if [ ! -f "$WF" ]; then echo absent
elif cmp -s "<skill-dir>/hosts/github-actions.yml" "$WF"; then echo identical
else echo differs; fi
```

- `identical`: show "Actions workflow: installed, agent <a>", `<a>` being what
  `gh variable get CREW_AGENT` prints (`copilot` when it fails), and move on; on "redo actions", ask
  the agent question below and run the commands after it.
- `absent`: ask "Run solve-feature on GitHub Actions, on a GitHub runner? [y/N]". On no, move on.
- `differs`: show `diff -u "$WF" "<skill-dir>/hosts/github-actions.yml"` and ask whether to replace the file
  with the template. Overwrite only on yes; on no, move on.

On yes, ask which agent CLI the runner uses, and keep the answer as `<agent>`:

- `copilot` (the default): billed to GitHub Copilot through the workflow's own token, no secret.
- `claude`: Claude Code, billed through a repo secret the user adds: `ANTHROPIC_API_KEY` (an Anthropic Console
  key) or `CLAUDE_CODE_OAUTH_TOKEN` (what `claude setup-token` prints, billed to their Claude subscription); or
  on AWS Bedrock with no secret, through repo variables and an IAM role coding-crew's `docs/guide.md` describes.

The caller's tag must be released (coding-crew installs from `main`, which can be ahead of its last release), so
the block checks it before writing anything:

```bash
TAG=$(sed -nE 's#^ *uses: ypxing/coding-crew/\.github/workflows/crew-solve-feature\.yml@([^ ]+)$#\1#p' "<skill-dir>/hosts/github-actions.yml")
if ! ERR=$(gh api "repos/ypxing/coding-crew/git/ref/tags/$TAG" 2>&1 >/dev/null); then
  if grep -q 'HTTP 404' <<<"$ERR"; then
    echo "coding-crew's workflow tag $TAG is not released yet: re-run after the release, or install from a release tag"
  else echo "$ERR"; fi
else
  mkdir -p .github/workflows
  cp "<skill-dir>/hosts/github-actions.yml" .github/workflows/solve-feature.yml
  gh label create run-agent --force
  gh variable set CREW_AGENT --body <agent>
fi
```

When it prints the not-released line or the tag check's error, nothing was written: say so and go to Step 4.

Once it wrote the caller, check the default branch: the workflow's token has `contents: write`, so on a branch with
no protection and no ruleset requiring a PR it can push there directly. Both reads need only read access; a failed
`gh` call prints its error and the block warns nothing:

```bash
if DEFAULT=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name) &&
  PROTECTED=$(gh api "repos/{owner}/{repo}/branches/$DEFAULT" --jq .protection.enabled) &&
  RULES=$(gh api "repos/{owner}/{repo}/rules/branches/$DEFAULT" --jq '.[].type') &&
  [ "$PROTECTED" = false ] && ! grep -qxE 'pull_request|update' <<<"$RULES"; then
  echo "Warning: nothing protects $DEFAULT, so the workflow's token can push straight to $DEFAULT. Add a ruleset with a pull_request rule for it (Settings → Rules → Rulesets)."
fi
```

Show the warning when it prints one; it changes nothing (`non_fast_forward` alone only blocks force pushes;
`.protection.enabled` is classic protection, while `.protected` is true for any ruleset).

The runner's fresh checkout has no `~/.coding-crew/`, so a tracker set only at user level reads as `local`
there. When the project's `config.json` has no `tracker` section, write it, keeping its other sections:

```bash
CONFIG=.coding-crew/config.json
if [ ! -f "$CONFIG" ] || [ "$(jq 'has("tracker")' "$CONFIG")" = false ]; then
  mkdir -p .coding-crew && { [ -f "$CONFIG" ] || echo '{}' > "$CONFIG"; }
  TMP=$(mktemp "$CONFIG.XXXXXX")
  if jq '.tracker = {kind: "github"}' "$CONFIG" > "$TMP"; then mv "$TMP" "$CONFIG"
    echo "Wrote tracker github to .coding-crew/config.json: the Actions runner sees only the project's files"
  else rm -f "$TMP"; fi
fi
```

If `jq` fails (the file is not valid JSON), show its error and leave the file as it is.

When a `gh` command fails, show its error as it printed it (it says what to fix, e.g. `gh auth login`) and
carry on to Step 4: the workflow file is written. Tell the user that once gh's error is fixed, they re-run
`/setup-coding-crew redo actions` (or run the failed `gh` command themselves): a plain re-run finds the
workflow `identical` and runs neither. With `claude`, tell the user to add the secret themselves with
`! gh secret set ANTHROPIC_API_KEY` (or `CLAUDE_CODE_OAUTH_TOKEN`), which prompts for the value; never ask for
it in the conversation. For Copilot's review of a PR a run marks ready, the user may add a fine-grained PAT with
Pull requests: write the same way, `! gh secret set COPILOT_GITHUB_TOKEN`; without it the job warns and they
request Copilot by hand. Then point the user to the reusable workflow's header comment (`# Billing`) for who pays
for the runs, and say how a run starts: label any issue of a feature `run-agent`, or run the workflow by hand with
the slug; and that a finished `ready-for-human` issue of a `run-agent` feature re-runs it. Tell them too that an issue whose change touches `.github/workflows/` cannot land from a runner — the
workflow's `GITHUB_TOKEN` never gets the `workflows` scope — so such an issue is run locally, for example with
`/solve-feature`; a run that hits one keeps its unpushed commits in the artifact's `unpushed.bundle`, and its
summary page prints the commands that fetch them. Last, tell them the file names a coding-crew release: to update, they bump the
tag on its `uses:` line (Dependabot's `github-actions` ecosystem opens those PRs), and its checks show on a PR as
`run / <job>`, so a branch rule that requires the old `solve` check needs the new name. An organisation that allows
only its own actions runs an internal copy of coding-crew instead: a mirror whose `stable` branch carries one
commit pointing the install line at the copy, which the callers name; coding-crew's `docs/guide.md` (solve-feature
on GitHub Actions) has the steps.

## Step 4 — Commit hint

Always, even after a step failed or was skipped, except after a stop in Step 2. Every run reads these files
before they are committed; committing them shares them with the team and with an Actions runner, whose fresh
checkout has only what is committed. List every setup file git shows as changed or untracked in the main
checkout, whether or not this run wrote it. Set `START` to the top level you were started in, and `UNVERIFIED` to
the checks the user kept failing in Step 2, space-separated (empty when none):

```bash
START="<the top level setup was started in>"
UNVERIFIED=""
MAIN=$(git rev-parse --path-format=absolute --git-common-dir)
[ "$(basename "$MAIN")" = .git ] && MAIN=$(dirname "$MAIN") || MAIN=$(git rev-parse --show-toplevel)
FILES=$(git -C "$MAIN" status --porcelain --untracked-files=all -- .coding-crew/config.json .coding-crew/dev-commands.json .github/workflows/solve-feature.yml | cut -c4- | LC_ALL=C sort | paste -sd' ' -)
for c in $UNVERIFIED; do echo "unverified: $c fails"; done
CD=""; [ "$MAIN" = "$START" ] || CD="cd $(printf '%q' "$MAIN") && "
if [ -n "$FILES" ]; then echo "To finish, run: ${CD}git add $FILES && git commit -m \"Set up coding-crew\""
else echo "Setup files are all committed: nothing to commit."; fi
```

Print its lines as they are; do not run them.
