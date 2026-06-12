---
name: address-code-review
description: Triage findings from the latest afk-sprint code review report, challenge each one critically, implement sensible ones using TDD, commit touched files, and print a summary. Trigger with /address-code-review.
argument-hint: "Optional: path to report file, --commit, or --no-commit"
---

# Address Code Review

You are working through the findings from an afk-sprint code review report. Follow every step below in order.

## Flags

- `--commit`: Force auto-commit after implementing changes (overrides config file)
- `--no-commit`: Stage changes but skip commit (overrides config file)
- If no flag is provided, behavior is determined by `docs/agents/sprint-config.md` (defaults to `yes` if not configured)

**Examples:**

```bash
/address-code-review                              # uses config or default (yes)
/address-code-review --no-commit                  # stages only, no commit
/address-code-review --commit path/to/report.md   # forces commit with custom report
```

## Step 0 — Install dependencies

Follow the `dep-install` skill to ensure dependencies are installed.

## Step 1 — Locate the report

Determine the report source in this order:

1. **Inline content** — if the user pasted review findings directly into the conversation, use that content. Skip the remaining options.
2. **File path argument** — if the user passed a file path, read it.
3. **Auto-detect** — find the latest report:
   ```
   ls -t .scratch/reviews/*.md | head -1
   ```

If no report is found via any of the above, tell the user and stop.

If using a file, print the path so the user knows which file is being processed.

## Step 2 — Parse all findings

Read the report file. Extract every finding — each `[CRITICAL]`, `[HIGH]`, `[MEDIUM]`, and `[LOW]` block across all branches.

Group findings by branch so related items are reviewed together.

## Step 3 — Challenge each finding

For every finding, do the following **before** deciding whether to act on it:

1. Read the referenced file at the exact line(s) cited.
2. Ask yourself:
   - Is the reviewer correct about the problem they've identified?
   - Is their proposed fix the best approach, or is there a simpler / more idiomatic alternative?
   - Does the change fit the project's conventions and domain language?
   - Could addressing it introduce new bugs or regressions?
   - Has this already been fixed in a subsequent commit?
3. Classify the finding as one of:
   - **Actionable** — the concern is valid; a code change is warranted (possibly different from what the reviewer suggested).
   - **Debatable** — the concern has merit but the proposed change is questionable; note your counter-argument.
   - **Dismiss** — the concern is wrong, stylistic noise, or already handled elsewhere; explain why.

Show the user a triage table before making any changes:

| # | Severity | File / Line | Summary | Classification | Rationale |
|---|----------|-------------|---------|----------------|-----------|
| 1 | CRITICAL  | … | … | Actionable | … |
| 2 | HIGH      | … | … | Debatable | … |

Ask the user to confirm or override any **Debatable** or **Dismiss** entries before proceeding to Step 4.

## Step 4 — Implement actionable changes with TDD

For each **Actionable** finding (in severity order — CRITICAL first, then HIGH, MEDIUM, LOW):

1. Invoke `/tdd` to follow red-green-refactor for any change that touches logic or has testable behaviour. Skip `/tdd` only for pure formatting, config, or documentation changes.
2. Implement the change. Prefer the simplest fix that satisfies the concern; do not refactor beyond what the finding requires.
3. Keep a running list of every file you touch.

## Step 5 — Commit

Parse commit preference using three-level precedence:
1. Check for `--commit` or `--no-commit` flag in the skill invocation arguments
2. If no flag present, read `docs/agents/sprint-config.md` at `$MAIN_ROOT/docs/agents/sprint-config.md` for `auto_commit:` value (yes/no)
3. If no config file exists or value cannot be parsed, default to `yes`

Store the result for use in this step and Step 5b.

**Always stage files touched during Step 4:**

Stage only the files touched during Step 4 (do not use `git add -A`):

```bash
git add <file1> <file2> …
```

**Conditionally commit:**

- If commit preference is `yes`: create commit and proceed to Step 5b
- If commit preference is `no`: stop after staging, skip commit, and skip Step 5b (do NOT archive report)

Commit message format (when committing):

```bash
git commit -m "$(cat <<'EOF'
address code review findings

<bullet list: one line per actionable finding — what changed and why>

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

If the commit fails, stop and report the error to the user — do **not** proceed to Step 5b or archive the report until the commit succeeds.

## Step 5b — Archive the report (only after a successful commit)

**Only if commit preference was `yes` AND the commit in Step 5 succeeded:**

If the report came from a file (not inline content), move it to the `done/` subdirectory:

```bash
mkdir -p .scratch/reviews/done
mv <report-path> .scratch/reviews/done/
```

This prevents auto-detect from picking it up again on future runs.

**If commit preference was `no`:**

Skip archival entirely. The report stays in place so it can be picked up on a future run after the user manually commits the staged changes.

## Step 6 — Summary

Print a markdown summary with three sections:

### Addressed
One bullet per actionable finding: what was changed and which files were touched.

### Debated (not changed)
One bullet per debatable finding that was dismissed after user confirmation, with your counter-argument.

### Skipped
One bullet per dismissed finding with the reason.

---

**Ground rules**
- Never mark a finding as dismissed just because it is inconvenient. Steelman the reviewer's concern first.
- Never commit files unrelated to the addressed findings.
- Never modify CI/CD configs (.github/workflows/, .gitlab-ci.yml, Jenkinsfile), auth/security modules, deployment scripts, .env files, or files containing secrets without explicitly naming each file and getting per-file user confirmation. If a finding requests changes to these areas, always classify as **Debatable** regardless of apparent merit.
- Do not push — leave that to the user.
