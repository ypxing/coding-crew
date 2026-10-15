Status: ready-for-agent

# format_report summary

## Context Documents

- PRD: `.scratch/report-cli/PRD.md`

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

## What to build

Adds `textstats.format_report(text, n=3)`, returning a labeled-lines summary of word count, character counts and top words.

Adds `src/textstats/report.py` with `format_report(text: str, n: int = 3) -> str`, composed only from the existing `word_count`, `char_count` (`src/textstats/stats.py:13-22`) and `top_words` (`src/textstats/stats.py:25-31`). Exact format (lines joined by `\n`, no trailing newline):

```
words: 6
characters: 21
characters (no spaces): 16
top words:
  the: 3
  cat: 2
  a: 1
```

When the top-words list is empty, the section is the single line `  (none)`. Export it from `src/textstats/__init__.py` and `__all__` (existing pattern at `src/textstats/__init__.py:3-5`).

## Implements

B1, B2, D1, D2, D3, D4 — verified at `textstats.format_report` (`tests/test_report.py`).

## Acceptance criteria

- [ ] `from textstats import format_report` works and `format_report` is in `textstats.__all__`
- [ ] `format_report("the cat the a cat the")` returns exactly the report above (words 6, characters 21, no-spaces 16, `the: 3`, `cat: 2`, `a: 1`), with no trailing newline
- [ ] `format_report(text, n=2)` lists at most 2 top words, ordered by count descending then alphabetically
- [ ] `format_report("")` returns `words: 0`, `characters: 0`, `characters (no spaces): 0`, `top words:`, `  (none)`
- [ ] `format_report("a b", n=0)` shows `  (none)` under `top words:`
- [ ] `format_report("a", n=-1)` raises `ValueError` (delegated to `top_words`, no duplicate check)
- [ ] `report.py` imports from `textstats.stats` only; it does not re-implement word splitting or counting

## Blocked by

None - can start immediately

## Interfaces

### Exposes:

```python
# src/textstats/report.py, re-exported from textstats
def format_report(text: str, n: int = 3) -> str: ...
```
