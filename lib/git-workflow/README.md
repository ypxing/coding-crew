# Git Workflow Scripts

## How It Works

The `coding-crew-lib` skill commits `skills/coding-crew-lib/scripts/git-workflow` as a link to
`../../../lib/git-workflow`, and an install copies it through the link, this directory included. A skill that runs
these scripts lists `coding-crew-lib` in its `deps` in `registry.json`:

```json
"solve-issue": {
  "deps": ["dep-install", "tdd", "configure-tracker", "coding-crew-lib"],
  ...
}
```

Skills run them from the `coding-crew-lib` skill installed beside them:
```bash
bash "<skill-dir>/../coding-crew-lib/scripts/git-workflow/commit-changes.sh" --message "..." --files "..."
```

`commit-changes.sh` exits 0 after a commit, 3 with a `nothing to commit` line when the named files leave nothing
staged, and 1 on any other error.
