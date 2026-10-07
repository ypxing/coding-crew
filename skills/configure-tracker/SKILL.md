---
name: configure-tracker
description: >
  Choose where the project's issues live — local markdown files or GitHub Issues — and write the
  choice to the `tracker` section of the repo's .coding-crew/config.json. Use when setting up a new
  project's issue tracker or switching tracker backends.
---

# Configure Tracker

Choose the project's issue tracker and record it in the repo's `.coding-crew/config.json`:

```json
{ "tracker": { "kind": "github" } }
```

Every other section of that file (`afk`) is kept. This is an explicit (re)configuration: an
existing `tracker` section is replaced.

## Step 1 — Offer the trackers

Show the current choice, if any:

```bash
CONFIG="$(git rev-parse --show-toplevel)/.coding-crew/config.json"
[ -f "$CONFIG" ] && jq -r '.tracker.kind // "none"' "$CONFIG"
```

Then present this menu:

```
Available trackers:
(1) local — markdown files under .scratch/<feature-slug>/issues/
(2) github — GitHub Issues and Milestones of this repo's git remote (needs an authenticated gh)
```

## Step 2 — Choose

Ask: "Which tracker? Enter a number."

Wait for the user to enter a valid number. If the input is invalid, re-prompt once; then stop.

## Step 3 — github setup

Only when the choice is `github`. Do the following before writing anything. Do not skip any
step, and do not proceed past a failure — surface it to the user with a clear message rather
than swallowing it. `gh` targets the repo of the current directory's git remote.

1. **Check authentication.** Run `gh auth status`. If it fails (non-zero exit), stop
   immediately with a clear error, e.g. "gh is not authenticated — run `gh auth login` first."
   Nothing below runs until this passes.
2. **Create the 7 labels idempotently.** For each of `needs-triage`, `needs-info`,
   `ready-for-agent`, `ready-for-human`, `awaiting-merge`, `blocked`, `in-progress`: check
   whether it already exists (`gh label list`); if missing, create it (`gh label create <name>`).
   Skip labels that already exist — do not error or duplicate. `awaiting-merge` is `done` before
   the PR merges; `blocked` marks an issue crew-afk stopped on (later runs skip it until a human
   removes the label); `in-progress` marks an issue a crew-afk run is working (display only, never
   read for dispatch); `wontfix` is a close reason, not a label — do not create `done` or
   `wontfix` as labels.

## Step 4 — Write config.json

Write the chosen kind (`local` or `github`) into the `tracker` section, keeping every other
section, then delete a legacy `issue-tracker.md` an earlier version wrote — it is no longer read
once `config.json` has a `tracker` section:

```bash
ROOT="$(git rev-parse --show-toplevel)"
CONFIG="$ROOT/.coding-crew/config.json"
mkdir -p "$ROOT/.coding-crew"
[ -f "$CONFIG" ] || echo '{}' > "$CONFIG"
TMP="$(mktemp "$CONFIG.XXXXXX")"
jq --arg k "<local|github>" '.tracker = {kind: $k}' "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"
rm -f "$ROOT/.coding-crew/docs/issue-tracker.md"
```

If `jq` fails (the existing `config.json` is not valid JSON), stop and show its error: never
replace a file you could not parse.

## Step 5 — Confirm

Print a confirmation message, naming the kind chosen:

```
Tracker configured: <kind> (.coding-crew/config.json). How it works: .coding-crew/tracker/docs/<kind>.md
```
