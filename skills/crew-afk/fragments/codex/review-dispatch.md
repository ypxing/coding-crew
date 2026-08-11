3. **Per-branch code review (after both gates pass, before merge):** dispatch `crew-code-reviewer`
   the same way, from the main checkout. It is read-only and advisory — it does not block the merge.

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

   The reviewer takes the coder's `$MODEL_FLAG`: omitting it silently reviews on another model.
