If `PRD.md` exists (output does not contain `"skipped"`), dispatch
`task(agent_type="general-purpose", prompt=...)` to generate a coverage report. Do **not** use a cheap
agent type or model tier: coverage validation does genuine reasoning (matching PRD requirements
against merged code and issue acceptance criteria):
