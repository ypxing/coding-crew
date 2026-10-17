# Git Workflow Scripts

## How It Works

Every skill whose `libs` in `registry.json` names it commits `skills/<skill>/scripts/git-workflow` as a link to
`../../../lib/git-workflow`, and an install copies the skill through it, this directory included:

```json
"solve-issue": {
  "libs": ["checks", "git-workflow", "tracker"],
  ...
}
```

Skills run them from their own copy:
```bash
bash "<skill-dir>/scripts/git-workflow/commit-changes.sh" --message "..." --files "..."
```
