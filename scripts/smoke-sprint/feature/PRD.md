# PRD: subtract

Status: ready-for-agent

## Problem

`src/math.js` can add two numbers but not subtract them.

## Decisions

- **D1** `src/math.js` exports `sub(a, b)`, returning `a - b`, next to `add`.
