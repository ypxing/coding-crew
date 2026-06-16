# Verification

Run all project checks and confirm every acceptance criterion from the issue is met.

## Checks

For crew:afk skill enhancements:

1. **Test** — Run the Session Init test script to verify feature branch setup logic
   ```bash
   bash skills/afk/references/test-session-init.sh
   ```

2. **Test** — Run the Sprint State Tracking test script to verify state persistence
   ```bash
   bash skills/afk/references/test-sprint-state.sh
   ```

3. **Manual verification** — Review the SKILL.md and copilot.SKILL.md files to ensure:
   - Session Init section has been enhanced with Feature Branch Setup
   - --jira flag parsing is implemented
   - First ready issue slug extraction is implemented
   - Default branch detection is implemented
   - Branch creation/switching logic is implemented
   - Feature-slug derivation is implemented
   - .scratch/<feature-slug>/issues/ directory creation is implemented
   - Sprint state tracking initialization is implemented
   - State file uses jq for JSON manipulation
   - State file contains branches object with base_sha and created_at fields

## Acceptance criteria

Check each criterion from the issue against the implemented code. All must pass before committing.
