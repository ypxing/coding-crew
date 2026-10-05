Status: ready-for-agent

# python -m textstats CLI happy path

## Context Documents

- PRD: `.scratch/report-cli/PRD.md`

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

## What to build

Adds `python -m textstats FILE [--top N]`, which reads `FILE` as UTF-8 and prints `format_report` for it.

Adds `src/textstats/__main__.py` with stdlib `argparse` (prog `textstats`), positional `FILE`, `--top N` (`int`, default 3), and `main(argv: list[str] | None = None) -> int` that returns the exit code; the module ends with `if __name__ == "__main__": raise SystemExit(main())`. It reads the file with `encoding="utf-8"` and calls `print(format_report(text, n=args.top))`.

## Implements

B3, D5 — verified at `textstats.__main__.main` and `python -m textstats` (`tests/test_cli.py`).

## Acceptance criteria

- [ ] `main([path])` on a UTF-8 file prints `format_report(contents)` followed by one newline to stdout and returns 0
- [ ] `main([path, "--top", "2"])` prints the report with at most 2 top words
- [ ] Without `--top`, the report lists up to 3 top words
- [ ] `python -m textstats FILE` run as a subprocess (`sys.executable -m textstats`) exits 0 and prints the report
- [ ] The file is decoded as UTF-8 regardless of locale (`encoding="utf-8"` passed explicitly)

## Blocked by

- `01-format-report.md`

## Interfaces

### Consumes:

```python
from textstats.report import format_report  # format_report(text: str, n: int = 3) -> str
```

### Exposes:

```python
# src/textstats/__main__.py
def main(argv: list[str] | None = None) -> int: ...
```
