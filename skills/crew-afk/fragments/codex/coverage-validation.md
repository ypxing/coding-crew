If `PRD.md` exists (output does not contain `"skipped"`), do the coverage validation yourself in
this session (there is no dedicated validation agent on Codex) using this prompt as your checklist. Do **not** use a cheap model tier for this step — coverage validation does genuine reasoning (matching PRD requirements against merged code and issue acceptance criteria):
