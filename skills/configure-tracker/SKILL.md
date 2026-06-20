---
name: configure-tracker
description: >
  Select and install an issue tracker template. Presents a numbered menu of available templates
  from docs/templates/trackers/, then writes the chosen template to the project-level config path.
  Use when setting up a new project's issue tracker or switching tracker backends.
---

# Configure Tracker

Select an issue tracker template and write it to the project-level config path.

## First-run deferral note

The automatic first-run prompt (triggered when a tracker-touching skill finds no project-level
config) is **not yet active**. It activates once 2+ templates exist in `docs/templates/trackers/`.
For now this skill is invoked manually only.

## Step 1 — List available templates

Find all `.md` files under `docs/templates/trackers/` relative to the repo root:

```bash
find "$(git rev-parse --show-toplevel)/docs/templates/trackers" -name "*.md" | sort
```

For each file, derive a short name (filename without `.md`) and a one-line description from
the first `#` heading inside the file if present; otherwise use the filename.

Present a numbered menu, for example:

```
Available tracker templates:
(1) local — Local markdown files in .scratch/
```

If no templates are found, stop: "No templates found in docs/templates/trackers/. Install one by copying a tracker template into that directory, or re-run the crew-agents install script."

## Step 2 — Choose a template

Ask: "Which template? Enter a number."

Wait for the user to enter a valid number. If the input is invalid, re-prompt once; then stop.

## Step 3 — Write the template

The destination is always the project-level path:
`$(git rev-parse --show-toplevel)/docs/agents/issue-tracker.md`

Copy the chosen template file to the destination, **overwriting any existing file**
(this is an explicit reconfiguration — no skip-if-exists guard here):

```bash
mkdir -p "$(dirname "<destination>")"
cp "<chosen-template-path>" "<destination>"
```

## Step 4 — Confirm

Print a confirmation message:

```
Tracker configured. All tracker-touching skills will now use <destination>.
```
