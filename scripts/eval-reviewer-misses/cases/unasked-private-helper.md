---
mode: branch
base_sha: 3d10b4b95431a48ccd8233ab3d50132461dcc8cc
head_sha: c9903c035e67d7c41011e2b214760ee6ebde4f91
slug: unasked-addition
via: origin/eval/unasked-addition-clean
clean: true
---
Over-flag control for `unasked-public-api`, on the same standalone bookshop fixture, range
`3d10b4b95431..c9903c035e67`. The change adds the requested `priceOf(id)` through a non-exported helper, `toCents`,
which its commit message mentions; `public-api.txt` and `docs/api.md` list `priceOf` only.

## Issue

bookshop-price-of

## Acceptance criteria

- [ ] `priceOf(id)` returns the book's price in cents
- [ ] It throws for an unknown book, as `getBook` does
- [ ] `priceOf` is public API, described in docs/api.md

## Reference judgement

No defect is known: the fixture was built to meet all three criteria, and `node --test` passes at the head. The helper
`toCents` is private to `books.js` (not exported, not in `public-api.txt` or `docs/api.md`): an implementation detail,
not an addition anyone relies on. Any finding about the helper is noise, whatever its level. Score `distinct` only;
any CRITICAL or HIGH finding is suspect.

## PRD

Other modules need a book's price without reading `BOOKS` directly.

- `priceOf(id)` returns the book's price in cents.
- It throws for an unknown book, as `getBook` does.
- `priceOf` is public API, described in docs/api.md.
