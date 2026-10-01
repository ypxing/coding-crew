# Re-run handling (local tracker)

Read this when `.scratch/<feature-slug>/issues/` already contains issue files.

**Re-run handling** (local tracker only — see the github paragraph below for that backend): Before writing, check if `.scratch/<feature-slug>/issues/` already contains issue files.

- If it does and a `done/` subdirectory exists with files in it, **stop** — tell the user: "Some issues are already completed. Please reconcile manually (delete or archive the old issues directory) before re-running."
- If it does but no issues are done (no `done/` subdirectory or it's empty), list the existing files, warn the user they'll be overwritten, and ask for confirmation before proceeding.
- If the directory doesn't exist or is empty, proceed normally.
