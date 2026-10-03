1. Resolve the target first if needed, then launch **in the background** — a dispatch can
   run up to 45 minutes — with `--dry-run` first only if the user asked what it would do.
   Use your tool's own background-process tracking, not a manual shell `&`/`disown` with
   redirected output — that bypasses the completion notification and no summary reaches
   you when the sprint finishes.
