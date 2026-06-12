---
name: address-pr-comments
description: Fetch all review comments on the current branch's open PR, challenge each one critically, implement sensible ones using TDD, commit touched files, and print a summary. Trigger with /address-pr-comments.
argument-hint: "Optional PR number or URL (defaults to current branch's open PR)"
---

# Address PR Comments

You are working through the review comments on a GitHub pull request. Follow every step below in order.

## Usage

```bash
/address-pr-comments [PR number or URL] [--commit | --no-commit]
```

**Flags:**
- `--commit` — always commit changes after staging (overrides config file)
- `--no-commit` — stage changes but skip commit (overrides config file)
- If no flag: uses `auto_commit` value from `docs/agents/sprint-config.md` (default: yes)

**Examples:**
```bash
# Auto-commit (default)
/address-pr-comments

# Review before committing
/address-pr-comments --no-commit

# Force commit even if config says no
/address-pr-comments --commit

# Specific PR with no-commit
/address-pr-comments 123 --no-commit
```

## Step 0 — Install dependencies and check prerequisites

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

Parse commit preference using three-level precedence:
1. Check for `--commit` or `--no-commit` flag in the skill invocation arguments
2. If no flag present, read `docs/agents/sprint-config.md` at `$MAIN_ROOT/docs/agents/sprint-config.md` for `auto_commit:` value (yes/no)
3. If no config file exists or value cannot be parsed, default to `yes`

Store the result for use in the commit logic below.

**Always stage files touched during Step 4:**

Stage only the files you changed — never `git add -A`.

```bash
git add <file1> <file2> ...
```

**Conditionally commit:**

- If commit preference is `yes`: create commit
- If commit preference is `no`: stop after staging; skip commit and proceed to Step 6

Commit message format (when committing):
```
address PR review comments

<bullet list: one line per actionable comment — what changed and why>

Co-Authored-By: Claude <noreply@anthropic.com>
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
