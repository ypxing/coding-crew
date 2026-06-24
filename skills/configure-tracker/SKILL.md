---
name: configure-tracker
description: >
  Select and install an issue tracker template. If only one template is available it is applied
  automatically; otherwise presents a numbered menu. Writes the chosen template to the
  project-level config path. Use when setting up a new project's issue tracker or switching
  tracker backends.
---

# Configure Tracker

Select an issue tracker template and write it to the project-level config path.

## Step 1 — List available templates

Search for `.md` files in two locations, preferring the project-level path:

1. `$(git rev-parse --show-toplevel)/.coding-crew/docs/templates/trackers/`
2. `~/.coding-crew/docs/templates/trackers/` (user-level fallback)

Collect templates from the first location that has any. If both are empty, stop with:
"No templates found in .coding-crew/docs/templates/trackers/. Re-run the crew-agents install script."

```bash
REPO_TRACKERS="$(git rev-parse --show-toplevel)/.coding-crew/docs/templates/trackers"
USER_TRACKERS="$HOME/.coding-crew/docs/templates/trackers"
if [ -d "$REPO_TRACKERS" ] && [ -n "$(find "$REPO_TRACKERS" -name "*.md" -print -quit 2>/dev/null)" ]; then
  TRACKERS_DIR="$REPO_TRACKERS"
elif [ -d "$USER_TRACKERS" ] && [ -n "$(find "$USER_TRACKERS" -name "*.md" -print -quit 2>/dev/null)" ]; then
  TRACKERS_DIR="$USER_TRACKERS"
else
  TRACKERS_DIR=""
fi
[ -n "$TRACKERS_DIR" ] && find "$TRACKERS_DIR" -name "*.md" | sort
```

For each file, derive a short name (filename without `.md`) and a one-line description from
the first `#` heading inside the file if present; otherwise use the filename.

If no templates are found, stop: "No templates found in .coding-crew/docs/templates/trackers/. Re-run the crew-agents install script."

**If exactly one template is found, skip Step 2 and use it automatically.**

Otherwise present a numbered menu, for example:

```
Available tracker templates:
(1) local — Local markdown files in .scratch/
(2) linear — Linear.app integration
```

## Step 2 — Choose a template

Ask: "Which template? Enter a number."

Wait for the user to enter a valid number. If the input is invalid, re-prompt once; then stop.

## Step 3 — Write the template

The destination is always the project-level path:
`$(git rev-parse --show-toplevel)/.coding-crew/docs/issue-tracker.md`

Copy the chosen template file to the destination, **overwriting any existing file**
(this is an explicit reconfiguration — no skip-if-exists guard here):

```bash
mkdir -p "$(dirname "<destination>")"
cp "<chosen-template-path>" "<destination>"
```

## Step 4 — Confirm

Print a confirmation message:

```
Tracker configured. All tracker-touching skills will now use .coding-crew/docs/issue-tracker.md.
```
