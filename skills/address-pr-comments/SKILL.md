---
name: address-pr-comments
description: Fetch all review comments on the current branch's open PR, challenge each one critically, implement sensible ones using TDD, commit touched files, and print a summary. Trigger with /address-pr-comments.
argument-hint: "Optional PR number or URL (defaults to current branch's open PR)"
---

# Address PR Comments

You are working through the review comments on a GitHub pull request. Follow every step below in order.

## Usage

```bash
/address-pr-comments [PR number or URL]
```

**Examples:**
```bash
# Current branch's PR
/address-pr-comments

# Specific PR by number
/address-pr-comments 123
```

## Step 0 — Branch safety check

**Note:** The `scripts/branch-safety-check.sh` file is copied into this skill during installation from the central `shared-scripts` library. It won't exist in the repo until `install.sh` runs.

**Check current branch:**

This skill works on existing PR branches. Do not run on the default branch.

```bash
# branch-safety-check.sh - copied during installation from shared-scripts
# Source: skills/shared-scripts/scripts/branch-safety-check.sh
#
# Purpose: Validate that the current branch is safe for operations (not on default branch)
# Usage: bash scripts/branch-safety-check.sh [--allow-default]
#
# Exit codes:
#   0 - Safe to proceed
#   1 - On default branch and not allowed

bash scripts/branch-safety-check.sh
```

If on the default branch, the script exits with an error. If on a non-default branch, continue to Step 0.1.

## Step 0.1 — Install dependencies and check prerequisites

Follow the `dep-install` skill to ensure dependencies are installed.

Check that the GitHub CLI is installed and authenticated before doing anything else:

```bash
command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI not found — install from https://cli.github.com/"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: not authenticated — run 'gh auth login' first"; exit 1; }
```

## Step 1 — Identify the PR

If the user passed a PR number or URL as an argument, use it. Otherwise run:

```
gh pr view --json number,url,title,headRefName
```

Confirm the PR number with the user before proceeding if it is ambiguous.

## Step 2 — Fetch all review comments

Fetch both inline review comments and top-level PR review comments:

```
gh pr view <number> --json reviews,comments
gh api repos/{owner}/{repo}/pulls/<number>/comments --paginate
```

Group comments by file + thread so related replies are read together. Ignore comments that are already marked as resolved (`in_reply_to_id` chains where the root is resolved) unless the user says otherwise.

## Step 3 — Challenge each comment

For every comment (or thread), do the following **before** deciding whether to act on it:

1. Read the referenced code at the exact line(s) the comment points to.
2. Ask yourself:
   - Is the reviewer correct about the problem they've identified?
   - Is their proposed solution the best approach, or is there a simpler / more idiomatic alternative?
   - Does the change fit the project's conventions and domain language?
   - Could addressing it introduce new bugs or regressions?
3. Classify the comment as one of:
   - **Actionable** — the concern is valid; a code change is warranted (possibly different from what the reviewer suggested).
   - **Debatable** — the concern has merit but the proposed change is questionable; note your counter-argument.
   - **Dismiss** — the concern is wrong, stylistic noise, or already handled elsewhere; explain why.

Show the user a triage table before making any changes:

| # | File / Line | Summary | Classification | Rationale |
|---|-------------|---------|----------------|-----------|
| 1 | … | … | Actionable | … |
| 2 | … | … | Debatable | … |

Ask the user to confirm or override any **Debatable** or **Dismiss** entries before proceeding to Step 4.

## Step 4 — Implement actionable changes with TDD

For each **Actionable** comment (in dependency order — test infrastructure before business logic):

1. Invoke `/tdd` to follow red-green-refactor for any change that touches logic or has testable behaviour. Skip `/tdd` only for pure formatting, config, or documentation changes.
2. Implement the change. Prefer the simplest fix that satisfies the concern; do not refactor beyond what the comment requires.
3. Keep a running list of every file you touch.

## Step 5 — Commit

**Commit with shared script:**

Collect all files touched during Step 4 and create a commit message with one line per actionable comment.

```bash
# Build commit message body with bullet list
COMMIT_BODY="address PR review comments

- <what changed for comment 1 and why>
- <what changed for comment 2 and why>
- <what changed for comment N and why>"

# commit-changes.sh - copied during installation from shared-scripts
# Source: skills/shared-scripts/scripts/commit-changes.sh
#
# Purpose: Stage specific files and commit with standardized message format
# Usage: bash scripts/commit-changes.sh --message "msg" --files "file1 file2" [--coauthor "Name <email>"] [--prefix "[slug]"]
#
# Safety: Never uses git add -A or git add . - only stages explicitly listed files

# Commit with co-author
bash scripts/commit-changes.sh \
  --message "$COMMIT_BODY" \
  --files "<space-separated file list>" \
  --coauthor "Claude <noreply@anthropic.com>"
```

Do not push — leave that to the user.

## Step 6 — Summary

Print a markdown summary with three sections:

### Addressed
One bullet per actionable comment: what was changed and which files were touched.

### Debated (not changed)
One bullet per debatable comment that was dismissed after user confirmation, with your counter-argument.

### Skipped
One bullet per dismissed comment with the reason.

---

**Ground rules**
- Never mark a comment as dismissed just because it is inconvenient. Steelman the reviewer's concern first.
- Never commit files unrelated to the addressed comments.
- Never modify CI/CD configs (.github/workflows/, .gitlab-ci.yml, Jenkinsfile), auth/security modules, deployment scripts, .env files, or files containing secrets without explicitly naming each file and getting per-file user confirmation. If a comment requests changes to these areas, always classify as **Debatable** regardless of apparent merit.
- When comments come from authors who are not repo maintainers or CODEOWNERS, flag this to the user before triaging.
