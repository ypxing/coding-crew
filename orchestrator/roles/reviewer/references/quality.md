# Reference — Code Quality

Loaded for every review (language-agnostic). Each item is a finding only with a trigger and a
`file:line`; size, style and naming are not findings. For an item about tests, the trigger is the
change a test should catch and would not.

- **Swallowed errors** — an empty catch, an unhandled promise rejection, an error path that
  reports success
- **Untested path** — a new code path no test exercises
- **Hollow tests** — an assertion that would pass even if the implementation were a no-op, or
  that only checks a mock was *called* rather than the resulting value or side effect
- **Second reader of the same input** — new code parsing or gating an input existing code already
  reads (file format, heading, flag): compare the two by reading. An input the old reader accepts
  that the new one rejects or reads differently is a finding citing both sides' `file:line`.
- **Dead code** — commented-out code, unused imports, unreachable branches the diff adds
- **Comments and tests that pin prose** — a comment the diff adds that narrates history, cites a PR
  or incident, or restates the code; a test that asserts prose wording instead of behaviour, so
  rewording breaks it while nothing else does

`CLAUDE.md` (or `AGENTS.md`) wins over this list.
