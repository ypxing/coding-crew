---
name: configure-tracker
description: >
  Chooses where the project's issues live — local markdown files or GitHub Issues — and writes the choice to
  the `tracker` section of the repo's .coding-crew/config.json, or of the user-level ~/.coding-crew/config.json
  for all the user's projects. Use when setting up a new project's issue tracker or switching tracker backends.
---

# Configure Tracker

Choose the issue tracker and record it in a `config.json`: the project's `.coding-crew/config.json` (the main
checkout's one even when run from a linked worktree, since the tracker reads it from there), or the user-level
`~/.coding-crew/config.json`, a default for every project that sets none:

```json
{ "tracker": { "kind": "github" } }
```

The tracker reads the project's `tracker` section first (or a legacy `.coding-crew/docs/issue-tracker.md`), then
the user file's, then defaults to `local`. Every other section of the file written (`solveFeature`) is kept. This
is an explicit (re)configuration: an existing `tracker` section in the chosen file is replaced.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it from the
source and at the scope they installed this skill from (`npx skills add <that source> -s coding-crew-lib`, adding
`-g` when this skill is installed at user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

## Step 1 — Offer the trackers

Show the current choice in each file, `none` where it sets none:

```bash
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"   # the main checkout, from a linked worktree too
ROOT="$(git rev-parse --show-toplevel)"; [ "$(basename "$COMMON")" != .git ] || ROOT="$(dirname "$COMMON")"
for LEVEL in "project:$ROOT/.coding-crew/config.json" "user:$HOME/.coding-crew/config.json"; do
  CONFIG="${LEVEL#*:}"
  echo "${LEVEL%%:*} ($CONFIG): $( [ -f "$CONFIG" ] && jq -r '.tracker.kind // "none"' "$CONFIG" || echo none)"
done
```

Then present this menu:

```
Available trackers:
(1) local — markdown files under .coding-crew/scratch/<feature-slug>/issues/
(2) github — GitHub Issues of this repo's git remote, a feature as a root issue and its sub-issues (needs an authenticated gh)
```

## Step 2 — Choose

Ask: "Which tracker? Enter a number."

Wait for the user to enter a valid number. If the input is invalid, re-prompt once; then stop.

Then ask: "Save for (1) this project (default) or (2) all your projects (user level)?" An empty answer is (1).
Keep `project` or `user` as the level.

## Step 3 — github setup

Only when the choice is `github`, before writing anything. `gh` targets the repo of the current directory's git
remote.

Run `gh auth status`. If it fails (non-zero exit), stop immediately with a clear error, e.g. "gh is not
authenticated — run `gh auth login` first." Nothing below runs until this passes. The tracker creates its
status labels itself, before it first applies one.

## Step 4 — Write config.json

Write the chosen kind (`local` or `github`) into the `tracker` section of the chosen level's file, keeping every
other section. At project level, then delete a legacy `issue-tracker.md` an earlier version wrote: it is no longer
read once `config.json` has a `tracker` section. At user level, leave the project untouched — its file is shared
team state, and its legacy `issue-tracker.md` stays in the lookup — and say when the project keeps its own:

```bash
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"   # the main checkout, from a linked worktree too
ROOT="$(git rev-parse --show-toplevel)"; [ "$(basename "$COMMON")" != .git ] || ROOT="$(dirname "$COMMON")"
LEVEL="<project|user>"
CONFIG="$ROOT/.coding-crew/config.json"; [ "$LEVEL" = project ] || CONFIG="$HOME/.coding-crew/config.json"
mkdir -p "$(dirname "$CONFIG")"
[ -f "$CONFIG" ] || echo '{}' > "$CONFIG"
TMP="$(mktemp "$CONFIG.XXXXXX")"
jq --arg k "<local|github>" '.tracker = {kind: $k}' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG" || { rm -f "$TMP"; exit 1; }
if [ "$LEVEL" = project ]; then rm -f "$ROOT/.coding-crew/docs/issue-tracker.md"
else
  P="$ROOT/.coding-crew/config.json" L="$ROOT/.coding-crew/docs/issue-tracker.md"
  if [ -f "$P" ] && [ "$(jq 'has("tracker")' "$P")" = true ]; then
    echo "This project keeps $(jq -r .tracker.kind "$P") from $P: remove its tracker section to use the user-level one."
  elif [ -f "$L" ]; then
    echo "This project keeps its tracker from $L: delete that file to use the user-level one."
  fi
fi
```

If `jq` fails (the existing `config.json` is not valid JSON), stop and show its error: never
replace a file you could not parse.

## Step 5 — Confirm

Print a confirmation message, naming the kind chosen and the file written (`$CONFIG`):

```
Tracker configured: <kind> (<file written>). How it works: <skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md
```
