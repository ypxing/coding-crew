# Verification (crew-afk pre-merge gate)

The policy `scripts/verify-worktree.sh` implements. The orchestrator does not run these commands
by hand — it calls the script and reads its exit code. This file documents what that exit code
means so the pre-filter in step 2 and the gate in step 3 cannot drift apart.

## Discovery chain

For each category, independently, first match wins:

1. A `Run: <command>` line under the matching section of `CLAUDE.md` (then `AGENTS.md`) at the
   worktree root.
2. A matching `Makefile` target.
3. Ecosystem conventions (`bats`, `npm test`, `pytest`, `cargo test`, `go test ./...`, …).

A `CLAUDE.md` that defines only the test command does not stop lint being resolved from the
Makefile.

## Order and outcomes

Run in this order — a type error makes a test failure meaningless:

1. **typecheck**
2. **lint**
3. **tests**

| Outcome | Exit | Meaning |
| --- | --- | --- |
| all discovered checks pass | 0 | writes the verification receipt for the current commit; the branch may merge |
| any discovered check fails | non-zero | clears any earlier receipt; demote to `partial`, do not merge |
| no **test** command discoverable | non-zero | nothing was verified — treated as a failure, not a pass |
| no **lint** and/or **typecheck** command discoverable | 0, plus `Verification: coverage gap — not_run: …` | not a blocker; many repos legitimately have neither. Carry the listed categories into the sprint summary so the round never reads as a clean pass |

A category with no discoverable command is always reported explicitly as `not_run`. It is never
silently treated as passing.

## Why the receipt matters

The gate is mechanical, not advisory. On exit 0 the script writes
`<main-root>/.scratch/<feature-slug>/dispatch/<issue-slug>.verify.ok` containing the gated commit
SHA, and `merge-branches.sh` refuses any `crew/<feature>/<issue>` branch whose receipt is missing or
whose SHA no longer matches the branch tip. Skipping verification, or adding commits after it, makes
the merge fail — re-run the script rather than working around the refusal.

## Acceptance criteria

Check verification does **not** check acceptance criteria. That is a separate gate, run after this
one and before the merge, and it leaves its own `.ac.ok` receipt that `close-issue.sh` demands.
