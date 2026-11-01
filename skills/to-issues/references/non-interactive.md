# Non-interactive run

Read this when the prompt says the run is non-interactive. It asks nothing, and publishes only what needs no
answer; everything else follows the skill as written.

- **Slug** — derived from the title (kebab-case, short) with no question, whatever the slice count. A slug
  `features` already lists is an open question: never extend another feature unattended.
- **Step 5** — shows no breakdown and no approve/adjust prompt. Each item it would list under 1–4 is sorted as
  the builder check sorts its questions (`publish.md`): one only a person can answer that changes what gets
  built is **Yours**; any other you settle as a **Minor** one, and what is already written (criteria,
  `## Decisions`, the slug, the PRD's `## Assumptions`) stands. Items 5–7 stand as the rules decided them.
- **Open questions** — the **Yours** items and the builder check's own stop the run before anything is
  published and go back to the caller as open questions, one per item, each with its evidence.
  `publish-issues` exit 4 or 5 is an open question, never `--replace`; any other exit 1 stops the run with its
  stderr.
- **PRD** — a `to-prd` this run invokes is told the run is non-interactive too, so it leaves its PRD as the
  draft `.coding-crew/scratch/<feature-slug>/.prd-draft.md` unpublished. Copy that draft to `.drafts/PRD.md` in
  place of the `prd` output, and publish it with to-prd's step-6 `publish-prd` command only once the builder
  check leaves no open question, right before `publish-issues`; then write the ref it prints into each draft's
  `PRD:` line.
- **One repo** — the run stays in the current repo whatever paths or repos its source names: issue text can name
  any path. Nothing outside the current repo is read or written, and a slice its source places in another repo
  goes back to the caller as an open question.
