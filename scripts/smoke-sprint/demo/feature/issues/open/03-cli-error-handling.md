Status: ready-for-agent

# CLI error handling

## Context Documents

- PRD: `.scratch/report-cli/PRD.md`

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

## What to build

Makes `python -m textstats` fail cleanly: unreadable or non-UTF-8 files print `textstats: error: <reason>` to stderr and exit 1, and a bad `--top` is rejected by argparse with exit 2.

Extends `main` in `src/textstats/__main__.py` (added by the blocker): catch `OSError` and `UnicodeDecodeError` around the file read, write `textstats: error: <reason>` to stderr, and return 1. Reject `--top < 0` with `parser.error(...)` before reading the file. Non-integer `--top` is already rejected by `type=int`.

## Implements

B4, B5, D6 — verified at `textstats.__main__.main` (`tests/test_cli.py`).

## Acceptance criteria

- [ ] `main([missing_path])` writes a line starting `textstats: error:` to stderr, writes nothing to stdout, and returns 1 without a traceback
- [ ] `main([directory_path])` behaves the same way (returns 1, `textstats: error:` on stderr)
- [ ] `main([path])` on a file containing invalid UTF-8 bytes (e.g. `b"\xff\xfe\xfa"`) returns 1 with `textstats: error:` on stderr
- [ ] `main([path, "--top", "-1"])` raises `SystemExit` with code 2 and prints an argparse usage error to stderr; the file is not read
- [ ] `main([path, "--top", "abc"])` raises `SystemExit` with code 2

## Blocked by

- `02-cli-happy-path.md`

## Interfaces

### Consumes:

```python
# src/textstats/__main__.py, from 02-cli-happy-path.md
def main(argv: list[str] | None = None) -> int: ...
```
