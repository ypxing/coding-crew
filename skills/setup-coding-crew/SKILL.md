---
name: setup-coding-crew
description: >
  Takes a repo from a fresh install to a working /solve-feature in one run: chooses the tracker with the
  configure-tracker skill, discovers the dev commands, saves them to .coding-crew/dev-commands.json and runs them, then prints the
  git commit line for the files it wrote. It never commits. Use when setting up coding-crew in a project, or to
  redo one of those steps. Trigger with /setup-coding-crew [redo tracker | redo commands].
argument-hint: "[redo tracker | redo commands]"
---

# Setup Coding Crew

Two steps and a commit hint, in this order: tracker, dev commands, commit hint. Run every
command from the main checkout, even when started in a linked worktree: every worktree of the clone reads the
setup files from there, committed or not. It is the parent of `git rev-parse --path-format=absolute --git-common-dir`
(the top level when that is not a `.git` directory); carry it as a literal. Note first the top level you were
started in (`git rev-parse --show-toplevel`): Step 3's commit line is for the user's shell there.

A re-run acts only on what is missing: a configured tracker and commands already in the dev commands file are
shown, not redone, and no file changes. When the user names a step ("change the tracker", "redo commands"), that
step runs again. Every run ends with Step 3.

This skill does not commit or push: it prints the command, and the user runs it.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it from the
source and at the scope they installed this skill from (`npx skills add <that source> -s coding-crew-lib`, adding
`-g` when this skill is installed at user level), or to re-run coding-crew's `install.sh`.
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
`Tracker: <kind>`.

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
eight fields again (`--refresh`) and replaces their `check:<name>` keys with the ones it finds, so a hand-added one
it does not find must be added back.

### Verify the commands

On a full run and on "redo commands" (not on "redo tracker"), run the commands now, so the
user sees them pass before committing them; a re-run is how a fixed command is verified. Use the dep-install skill
to decide the install mode (it saves `install_mode` into the dev commands file when that is missing) and install,
then, from the main checkout:

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run-checks.sh" --project-root "$PWD"
```

On every run, pass or fail, its `<key>: rewrote: <files>` lines are a check that fixed those files (a
`lint --fix`): name them to the user, and carry every file any run named to Step 3's commit line.

- `CHECKS: pass`: say so, and go on.
- `CHECKS: fail`: show each failing check's output, then ask the user, per failing check: **fix** the command
  (edit it in `$DEV` with them, then run `run-checks.sh` again), **keep** it as it is (Step 3 labels it
  unverified), or **stop**. On stop, end the run here, without Step 3's commit line.

## Step 3 — Commit hint

Always, even after a step failed or was skipped, except after a stop in Step 2. Every run reads these files
before they are committed; committing them shares them with the team, and with any fresh
checkout, which has only what is committed. List every setup file git shows as changed or untracked in the main
checkout, whether or not this run wrote it. Set `START` to the top level you were started in, and `UNVERIFIED` to
the checks the user kept failing in Step 2, space-separated, and `REWROTE` to the files Step 2's `rewrote:` lines
named, one quoted array item per file (both empty when none):

```bash
START="<the top level setup was started in>"
UNVERIFIED=""
REWROTE=()
MAIN=$(git rev-parse --path-format=absolute --git-common-dir)
[ "$(basename "$MAIN")" = .git ] && MAIN=$(dirname "$MAIN") || MAIN=$(git rev-parse --show-toplevel)
changed() { git -C "$MAIN" status --porcelain -z --no-renames --untracked-files=all -- "$@" |
  while IFS= read -r -d '' e; do printf '%s\0' "${e:3}"; done | LC_ALL=C sort -z; }
FILES=""
while IFS= read -r -d '' f; do FILES+="${FILES:+ }$(printf '%q' "$f")"; done < <(changed .coding-crew/config.json .coding-crew/dev-commands.json "${REWROTE[@]}")
for c in $UNVERIFIED; do echo "unverified: $c fails"; done
CD=""; [ "$MAIN" = "$START" ] || CD="cd $(printf '%q' "$MAIN") && "
if [ -n "$FILES" ]; then echo "To finish, run: ${CD}git add $FILES && git commit -m \"Set up coding-crew\""
else echo "Setup files are all committed: nothing to commit."; fi
```

Print its lines as they are; do not run them.
