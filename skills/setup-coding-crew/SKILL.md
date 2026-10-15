---
name: setup-coding-crew
description: >
  Takes a repo from a fresh install to a working /solve-feature in one run: chooses the tracker with the
  configure-tracker skill, discovers and saves the check commands to .coding-crew/dev-commands.json, with the
  github tracker optionally installs the solve-feature GitHub Actions workflow and its label, then prints the
  git commit line for the files it wrote. It never commits. Use when setting up coding-crew in a project, or to
  redo one of those steps. Trigger with /setup-coding-crew [redo tracker | redo commands | redo actions].
argument-hint: "[redo tracker | redo commands | redo actions]"
---

# Setup Coding Crew

Three steps and a commit hint, in this order: tracker, check commands, GitHub Actions, commit hint. Run every
command from the repo root (`git rev-parse --show-toplevel`).

A re-run acts only on what is missing: a configured tracker, cached commands and a workflow identical to the
template are shown, not redone, and no file changes. When the user names a step ("change the tracker", "redo
commands", "redo actions"), that step runs again. Every run ends with Step 4.

This skill does not commit or push: it prints the command, and the user runs it.

{{FRAGMENT:tracker-configuration}}

## Step 1 — Tracker

```bash
node "$TRACKER" config
```

On `configured=no`, or when the user asks to change the tracker: Use the configure-tracker skill, then run
`config` again. Otherwise show `Tracker: <kind>` and move on. Keep the kind for Step 3.

## Step 2 — Check commands

solve-feature gates every issue on these commands, and a GitHub Actions runner sees only what is committed, so
they live in the tracked `.coding-crew/dev-commands.json`. When that file is absent, start it from the clone's own
cache (what an earlier `/solve-issue` discovered), else empty, then run discovery — with `--refresh` when the
user said "redo commands", which asks all eight fields again:

```bash
DEV=.coding-crew/dev-commands.json
if [ ! -f "$DEV" ]; then
  CLONE=$(bash "<skill-dir>/scripts/checks/commands-file.sh" --project-root "$PWD")
  mkdir -p .coding-crew
  if [ -f "$CLONE" ]; then cp "$CLONE" "$DEV"; else echo '{}' > "$DEV"; fi
fi
bash "<skill-dir>/scripts/checks/discover-commands.sh"   # --refresh on "redo commands"
```

- **A prompt** (`Command discovery: <n> source file(s) found`): answer it yourself by reading the files it
  lists. Show the user the proposed commands, one per line, and take their corrections. Write the corrected
  answer, in the JSON shape the prompt asks for, to `.discovered-commands.json` and save it:

  ```bash
  bash "<skill-dir>/scripts/checks/write-commands-cache.sh" --response-file .discovered-commands.json
  rm -f .discovered-commands.json
  ```

- **`Command discovery: skipped`**: there is nothing to ask. Show what `$DEV` holds. If it has no `"test"`
  key — discovery found none of the files it reads — solve-feature would stop at its first check, so ask the
  user for test, lint and typecheck, offering the ecosystem's convention as each default (`npm test`,
  `pytest`, `go test ./...`, `cargo test`, `bundle exec rspec`; `npx eslint .`, `ruff check .`,
  `golangci-lint run`; `npx tsc --noEmit`, `mypy .`, `go vet ./...`), `null` for one the project has none of.
  Write the answers to `.discovered-commands.json` and save them with `write-commands-cache.sh` as above.

Never run the commands: this step only records them.

When `test`, `lint` and `typecheck` are all `null`, warn: "solve-feature will land issues with no checks run:
each prints `NOT RUN` and the run passes."

Then tell the user: `.coding-crew/dev-commands.json` is plain JSON they can edit by hand at any time; a re-run
keeps their edits, since discovery never re-asks a field already there; and saying "redo commands" discovers all
eight fields again (`--refresh`).

## Step 3 — GitHub Actions

Only with `tracker=github`. With `local`, say "The solve-feature Actions workflow needs the github tracker: its
label trigger reads a root issue's `Feature:` line, and `.scratch/` issues are not in the runner's checkout",
and go to Step 4.

```bash
WF=.github/workflows/solve-feature.yml
if [ ! -f "$WF" ]; then echo absent
elif cmp -s "<skill-dir>/hosts/github-actions.yml" "$WF"; then echo identical
else echo differs; fi
```

- `identical`: show "Actions workflow: installed" and move on (on "redo actions", run the label command below).
- `absent`: ask "Run solve-feature on GitHub Actions — the Copilot CLI on a GitHub runner, billed to GitHub
  Copilot? [y/N]". On no, move on.
- `differs`: show `diff -u "$WF" "<skill-dir>/hosts/github-actions.yml"` and ask whether to replace the file
  with the template. Overwrite only on yes; on no, move on.

On yes:

```bash
mkdir -p .github/workflows
cp "<skill-dir>/hosts/github-actions.yml" .github/workflows/solve-feature.yml
gh label create solve-feature --force
```

When `gh label create` fails, show gh's error as it printed it (it says what to fix, e.g. `gh auth login`) and
carry on to Step 4: the workflow file is written. Then point the user to the workflow's header comment
(`# Billing:`) for who pays for the runs, and say how a run starts: label a feature's root issue
`solve-feature`, or run the workflow by hand with the slug.

## Step 4 — Commit hint

Always, even after a step failed or was skipped. solve-feature needs these files committed: its start refuses a
dirty tree, and an Actions runner's fresh checkout has only what is committed. List every setup file git shows
as changed or untracked, whether or not this run wrote it:

```bash
FILES=$(git status --porcelain --untracked-files=all -- .coding-crew/config.json .coding-crew/dev-commands.json .github/workflows/solve-feature.yml | cut -c4- | LC_ALL=C sort | paste -sd' ' -)
if [ -n "$FILES" ]; then echo "To finish, run: git add $FILES && git commit -m \"Set up coding-crew\""
else echo "Setup files are all committed: nothing to commit."; fi
```

Print its line as it is; do not run it.
