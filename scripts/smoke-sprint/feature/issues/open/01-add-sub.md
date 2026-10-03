# 01 — Add sub()

Status: ready-for-agent

## Parent

.scratch/subtract/PRD.md

## Implements

- D1

## What to build

Export `sub(a, b)` from `src/math.js`, returning `a - b`, and cover it in `test/math.test.js`.

## Acceptance criteria

- [ ] `src/math.js` exports `sub(a, b)` returning `a - b`
- [ ] `add` is unchanged and its existing test still passes
- [ ] `test/math.test.js` tests `sub`, including a negative result, and passes under `npm test`

## Blocked by

None - can start immediately
