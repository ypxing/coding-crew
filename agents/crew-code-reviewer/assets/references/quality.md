# Reference — Code Quality, Performance, Best Practices

Loaded for every review (language-agnostic thresholds). Every item still passes the Pre-Report
Gate and the Common False Positives list in the protocol before it becomes a finding.

## Code Quality (HIGH)

- **Large functions** (>50 lines) — split into smaller, focused functions
- **Large files** (>800 lines) — extract modules by responsibility
- **Deep nesting** (>4 levels) — use early returns, extract helpers
- **Missing error handling** — unhandled promise rejections, empty catch blocks
- **Mutation patterns** — prefer immutable operations (spread, map, filter)
- **console.log statements** — remove debug logging before merge
- **Missing tests** — new code paths without test coverage
- **Dead code** — commented-out code, unused imports, unreachable branches

## Performance (MEDIUM)

- **Inefficient algorithms** — O(n²) when O(n log n) or O(n) is possible
- **Large bundle sizes** — importing entire libraries when tree-shakeable alternatives exist
- **Missing caching** — repeated expensive computations without memoization
- **Synchronous I/O** — blocking operations in async contexts

## Best Practices (LOW)

- **TODO/FIXME without tickets** — TODOs should reference issue numbers
- **Missing JSDoc for public APIs** — exported functions without documentation
- **Poor naming** — single-letter variables in non-trivial contexts
- **Inconsistent formatting** — mixed semicolons, quote styles, indentation

## Project-specific overrides

`CLAUDE.md` wins over every threshold above — file size limits, immutability requirements,
database policies (RLS, migration patterns), error handling patterns (custom error classes, error
boundaries), and state management conventions. When in doubt, match what the rest of the codebase
does.
