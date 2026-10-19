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

<!-- fragment:tracker-configuration -->
## Tracker Configuration

Every tracker op runs through the tracker CLI, `TRACKER=<skill-dir>/scripts/tracker/cli.mjs` (`<skill-dir>` being the
directory you read this file from), as `node "$TRACKER" <op> …`; nothing else reads or writes the tracker. Before the
first op run `node "$TRACKER" config` (prints `tracker=<kind>` and `configured=yes|no`). On `configured=no` on an
interactive run, invoke the `configure-tracker` skill, then continue; on a non-interactive run (a headless/`-p`
invocation or a subagent) never ask: proceed as `local`. The tracker's refs, statuses and labels are in
`<skill-dir>/scripts/tracker/docs/<kind>.md`.

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
DEV=$(bash "<skill-dir>/scripts/checks/commands-file.sh" --project-root "$PWD")
OLD="$(git rev-parse --path-format=absolute --git-common-dir)/coding-crew/dev-commands.json"
if [ ! -f "$DEV" ]; then
  mkdir -p "$(dirname "$DEV")"
  if [ -f "$OLD" ]; then mv "$OLD" "$DEV"; else echo '{}' > "$DEV"; fi
fi
cd "$(dirname "$(dirname "$DEV")")" && bash "<skill-dir>/scripts/checks/discover-commands.sh"   # --refresh on "redo commands"
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
bash "<skill-dir>/scripts/checks/run-checks.sh" --project-root "$PWD"
```

- `CHECKS: pass`: say so, and go on.
- `CHECKS: fail`: show each failing check's output, then ask the user, per failing check: **fix** the command
  (edit it in `$DEV` with them, then run `run-checks.sh` again), **keep** it as it is (Step 4 labels it
  unverified), or **stop**. On stop, end the run here, without Step 4's commit line.

## Step 3 — GitHub Actions

Only with `tracker=github`. With `local`, say "The solve-feature Actions workflow needs the github tracker: its
label trigger reads a root issue's `Feature:` line, and `.coding-crew/scratch/` issues are not in the runner's checkout",
and go to Step 4.

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
  key) or `CLAUDE_CODE_OAUTH_TOKEN` (what `claude setup-token` prints, billed to their Claude subscription).

```bash
mkdir -p .github/workflows
cp "<skill-dir>/hosts/github-actions.yml" .github/workflows/solve-feature.yml
gh label create run-agent --force
gh variable set CREW_AGENT --body <agent>
```

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
it in the conversation. Then point the user to the workflow's header comment (`# Billing`) for who pays for the
runs, and say how a run starts: label a feature's root issue `run-agent`, or run the workflow by hand with
the slug. Tell them too that an issue whose change touches `.github/workflows/` cannot land from a runner — the
workflow's `GITHUB_TOKEN` never gets the `workflows` scope — so such an issue is run locally, for example with
`/solve-feature`; a run that hits one keeps its unpushed commits in the artifact's `unpushed.bundle`, and its
summary page prints the commands that fetch them.

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
