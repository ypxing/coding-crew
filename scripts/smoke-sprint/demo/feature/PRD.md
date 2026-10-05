Status: ready-for-agent

# PRD: textstats report and CLI

## Problem Statement

Actor: a user of the `textstats` library who wants stats for a file.

`textstats` only exposes individual functions (`words`, `word_count`, `char_count`, `top_words` —
`src/textstats/stats.py:9-31`). Getting a summary of a file means writing Python glue each time;
there is no human-readable summary and no command-line entry point.

## Solution

Add a `report` module whose `format_report(text, n=3)` returns a plain-text summary (word count,
character counts with and without whitespace, top `n` words), and a CLI
`python -m textstats FILE [--top N]` that reads `FILE` and prints that summary.

## Behaviours

- **B1** — given text `"the cat the a cat the"`, `format_report(text)` returns exactly the labeled-lines report (see D2) with `the: 3`, `cat: 2`, `a: 1`, at `textstats.format_report`
- **B2** — given empty text, or `n=0`, the `top words:` section contains the single line `  (none)`, at `textstats.format_report`
- **B3** — given a readable UTF-8 file, `python -m textstats FILE --top 2` prints the report with at most 2 top words and exits 0, at `textstats.__main__.main` / `python -m textstats`
- **B4** — given a missing, unreadable, or non-UTF-8 file, the CLI prints `textstats: error: <reason>` to stderr, prints nothing to stdout, and exits 1, at `textstats.__main__.main`
- **B5** — given `--top -1` (or a non-integer), argparse rejects it with a usage error and exit code 2, at `textstats.__main__.main`

## Decisions

- **D1** — New module `src/textstats/report.py` exposing `format_report(text: str, n: int = 3) -> str`. It is composed solely from `textstats.stats` (`word_count`, `char_count`, `top_words`); no counting logic is re-implemented. Dependency direction: `__main__` → `report` → `stats`, never the reverse. Default `n=3` matches `top_words` (`src/textstats/stats.py:25`). (auto)
- **D2** — Report format is labeled lines (user-chosen). Exact shape, lines joined by `\n`, **no trailing newline** (the CLI's `print` adds it) (auto for the trailing-newline part):
  ```
  words: 9
  characters: 42
  characters (no spaces): 34
  top words:
    the: 3
    cat: 2
    a: 1
  ```
  `characters` = `char_count(text)`; `characters (no spaces)` = `char_count(text, include_spaces=False)`. Top words are indented two spaces as `word: count`, in `top_words` order (count desc, then alphabetical — `src/textstats/stats.py:26-31`). When the top-words list is empty, emit `  (none)`.
- **D3** — `format_report` raises `ValueError` for `n < 0` by delegating to `top_words` (`src/textstats/stats.py:27-28`); no separate check. (auto)
- **D4** — Export `format_report` from `src/textstats/__init__.py` and add it to `__all__`, following the existing pattern (`src/textstats/__init__.py:3-5`). (auto)
- **D5** — CLI lives in `src/textstats/__main__.py`, uses stdlib `argparse` (prog `textstats`), positional `FILE`, `--top N` (`int`, default 3). Exposes `main(argv: list[str] | None = None) -> int` and ends with `if __name__ == "__main__": raise SystemExit(main())`. `main` returns the exit code rather than calling `sys.exit` itself, so tests can call it directly. (auto)
- **D6** — Negative `--top` is rejected via argparse (`parser.error`, exit 2) before any file is read. File is read with `encoding="utf-8"`; `OSError` and `UnicodeDecodeError` print `textstats: error: <reason>` to stderr and return 1. (auto)
- **D7** — No new runtime dependencies; `pyproject.toml:6` stays `dependencies = []`. (no slice)
- **D8** — All new code must pass `ruff` (rules `E,F,I,B,UP`, line length 100, py310 target) and `mypy --strict` over `src` and `tests` (`pyproject.toml:20-31`). Code must stay Python 3.10-compatible (`pyproject.toml:5`). (no slice)

## Trust Boundaries & Risks

- **File path from the command line** — user-supplied `FILE` is read as UTF-8 text. Missing file, permission error, directory, or invalid UTF-8 → `textstats: error: <reason>` on stderr, exit 1, no traceback (D6). No other input crosses a boundary; no shell, network or secrets.

## Testing Decisions

- Test observable behaviour only: the exact returned string of `format_report` and the stdout/stderr/exit code of `main`.
- `tests/test_report.py` — exact-string assertions for a normal text, empty text, `n=0`, ties ordering, and `ValueError` on negative `n`.
- `tests/test_cli.py` — call `main([...])` with `tmp_path` files and `capsys`; cover success, `--top`, missing file, invalid UTF-8 (write raw bytes), and `--top -1` (`pytest.raises(SystemExit)` with code 2). One subprocess smoke test running `sys.executable -m textstats FILE` to prove `__main__` wiring.
- Prior art: `tests/test_stats.py` — plain pytest functions, `-> None` annotations (required by mypy strict), imports from the `textstats` package, `pytest.raises` for errors.
- Checks: `uv run pytest && uv run ruff check . && uv run mypy .` (`README.md:8`).

## Out of Scope

- `[project.scripts]` console entry point — user asked for `python -m textstats` only.
- Reading stdin (`-`) — no stated need.
- JSON / machine-readable output — no stated need.
- Multiple FILE arguments — no stated need.
- README usage section — nothing breaks without it; cut in design.

## Further Notes

- No `CLAUDE.md` exists, so there are no named axes of variation; the report format is deliberately not pluggable.
