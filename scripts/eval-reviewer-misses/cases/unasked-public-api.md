---
mode: branch
base_sha: 3d10b4b95431a48ccd8233ab3d50132461dcc8cc
head_sha: be850ad274261dd405a0bd4780a3f12b0a4f7502
slug: unasked-addition
via: origin/eval/unasked-addition
---
Replay of a field repo's per-branch review, rebuilt as a standalone bookshop fixture, range `3d10b4b95431..be850ad27426`.
The issue asked for one public function, `priceOf(id)`; the change also adds a second, `priceOfFormatted(id)`, lists it
in `public-api.txt` and `docs/api.md`, tests it, and announces it in its commit message. In the field repo the
reviewer passed it as declared scope in 3 of 3 runs.

## Issue

bookshop-price-of

## Acceptance criteria

- [ ] `priceOf(id)` returns the book's price in cents
- [ ] It throws for an unknown book, as `getBook` does
- [ ] `priceOf` is public API, described in docs/api.md

## Expected misses

- unasked-public-api: the change adds an exported `priceOfFormatted(id)`, listed in `public-api.txt` and `docs/api.md`, that the issue did not ask for — unrequested public API others will come to rely on

## Reference judgement

The issue asks for one function, `priceOf(id)`; `books.js` at the head also exports `priceOfFormatted(id)`, and
`public-api.txt` and `docs/api.md` list it as public API. Nothing in the issue asks for it, and the commit message
announcing it is the change's own claim, not a requirement. Once public it is a contract other modules come to rely on,
so it is a HIGH finding. A report counts as caught only for a finding (not a gap and not a notes entry) at HIGH that
flags `priceOfFormatted` as public API the spec did not ask for. LOW or MEDIUM does not count, nor does a finding only
on its code quality (its formatting, rounding or currency handling). `priceOf` itself meets all three criteria and the
tests pass: any finding against it is noise.

## PRD

Other modules need a book's price without reading `BOOKS` directly.

- `priceOf(id)` returns the book's price in cents.
- It throws for an unknown book, as `getBook` does.
- `priceOf` is public API, described in docs/api.md.
