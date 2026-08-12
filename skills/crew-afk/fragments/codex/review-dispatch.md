2. **Per-branch code review (after verification passes, before the merge):** dispatch
   `crew-code-reviewer` the same way, from the main checkout. It is read-only, reads the diff itself,
   and returns the acceptance-criteria verdict together with its advisory findings.

   ```bash
   cat > "$DISPATCH_DIR/$SLUG.review-prompt.md" <<PROMPT
   Review this branch before it merges.
   Branch: $BRANCH
   Slug: $SLUG
   Issue file: <issue-file-path>
   Acceptance criteria:
   <criteria verbatim from the issue>

   Gather the diff: git diff \$(git merge-base $FEATURE_BRANCH $BRANCH)..$BRANCH
   PROMPT

   bash "<skill-dir>/scripts/dispatch-codex-agent.sh" \
     --agent crew-code-reviewer \
     --dir "$MAIN_ROOT" \
     --prompt-file "$DISPATCH_DIR/$SLUG.review-prompt.md" \
     --out "$DISPATCH_DIR/$SLUG.review.md" \
     --log "$TRACE_LOG" \
     $MODEL_FLAG

   grep -m1 '^AC:' "$DISPATCH_DIR/$SLUG.review.md" || echo "AC: unmet — no verdict"
   ```

   The reviewer takes the coder's `$MODEL_FLAG`: omitting it silently reviews on another model. That
   last `grep` is the verdict this branch is gated on — read it, do not infer it.
