3. **Per-branch code review (after both verification gates pass, before merge):** dispatch
   `crew-code-reviewer` the same way, from the main checkout. The reviewer is read-only and does not
   block the merge — findings are advisory.

   ```bash
   cat > "$DISPATCH_DIR/$SLUG.review-prompt.md" <<PROMPT
   Review this branch before it merges.
   Branch: $BRANCH
   Slug: $SLUG
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
   ```

   The reviewer takes the same `$MODEL_FLAG` as the coder — omitting it here would silently review
   on a different model than the sprint was asked to run on.
