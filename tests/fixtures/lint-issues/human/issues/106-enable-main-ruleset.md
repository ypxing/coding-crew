Status: ready-for-human

## What to build

Make the `main` branch ruleset enforce the rules the project relies on: a pull request can only merge when the test checks are green and the branch is up to date with `main`.

## For a human

### Why a person

Only a repository admin can edit rulesets, and the change is made on GitHub itself, not in code. An agent has no admin token and must not have one.

### What changes

Today the ruleset (id `17743259` on `ypxing/coding-crew`) is `enforcement: active` with no bypass actors. It has four rules: `deletion`, `non_fast_forward`, `required_linear_history`, and `pull_request` (squash merges only, 0 required approvals, code-owner review required). It has no `required_status_checks` rule, so a PR can merge while its tests are red.

After this change the ruleset keeps every rule above, except code-owner review is no longer required, and gains a `required_status_checks` rule. The rule is strict, so a PR must be up to date with `main`. The required checks are `Test on ubuntu-latest 1/1` and `Test on macos-latest 1/3`, `2/3`, `3/3`.

### Steps

1. Save the current ruleset so you can undo this. Check: the file is not empty.

   ```bash
   gh api repos/ypxing/coding-crew/rulesets/17743259 > ruleset.backup.json
   test -s ruleset.backup.json && echo saved
   ```

2. Create `ruleset.json` with the content below. `PUT` replaces the whole `rules` array, so every existing rule has to be listed again, or it is deleted. Check: `jq` parses it and prints five types.

   ```json ruleset.json
   {
     "name": "main",
     "target": "branch",
     "enforcement": "active",
     "bypass_actors": [],
     "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
     "rules": [
       { "type": "deletion" },
       { "type": "non_fast_forward" },
       { "type": "required_linear_history" },
       {
         "type": "pull_request",
         "parameters": {
           "allowed_merge_methods": ["squash"],
           "required_approving_review_count": 0,
           "require_code_owner_review": false,
           "require_extra_approval_for_unattributed_changes": true,
           "dismiss_stale_reviews_on_push": false,
           "require_last_push_approval": false,
           "required_review_thread_resolution": false
         }
       },
       {
         "type": "required_status_checks",
         "parameters": {
           "strict_required_status_checks_policy": true,
           "required_status_checks": [
             { "context": "Test on ubuntu-latest 1/1" },
             { "context": "Test on macos-latest 1/3" },
             { "context": "Test on macos-latest 2/3" },
             { "context": "Test on macos-latest 3/3" }
           ]
         }
       }
     ]
   }
   ```

   ```bash
   jq -r '.rules[].type' ruleset.json
   ```

3. Apply it. Check: the command prints JSON with no `message` error.

   ```bash
   gh api -X PUT repos/ypxing/coding-crew/rulesets/17743259 --input ruleset.json
   ```

4. Read it back. Check: `required_status_checks` is in the list.

   ```bash
   gh api repos/ypxing/coding-crew/rulesets/17743259 --jq '.rules[].type'
   ```

To undo, send the saved file back: `gh api -X PUT repos/ypxing/coding-crew/rulesets/17743259 --input ruleset.backup.json`.

### If skipped or done wrong

If skipped, a PR can merge with red tests, or while behind `main`. If `ruleset.json` leaves out an existing rule, that rule is silently removed.

### Done when

The read-back in step 4 lists all five rule types, and a test PR with a failing check cannot be merged.

## Acceptance criteria

- [ ] The ruleset has a `required_status_checks` rule with the four contexts and the strict policy
- [ ] The four original rules are still present
- [ ] A PR with a failing check shows merging as blocked
