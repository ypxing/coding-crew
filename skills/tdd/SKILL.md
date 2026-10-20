---
name: tdd
description: >
  Guides test-driven development through a red-green-refactor loop. Use when the user wants to build features
  or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first
  development.
---

# Test-Driven Development

## Philosophy

**Core principle**: tests verify behaviour through public interfaces, not implementation details.
Code can change entirely; tests shouldn't. A good test reads like a specification — "user can
checkout with valid cart" — and survives a refactor because it does not know the internal structure.
The warning sign of a bad one: it breaks when you rename an internal function, though behaviour did
not change.

See the `references/` directory alongside this skill file for supporting material: `tests.md` (examples) and `mocking.md` (mocking guidelines). Read them from the same directory you read this skill file from.

## Anti-Pattern: Horizontal Slices

**DO NOT write all tests first, then all implementation** — RED as "write all tests", GREEN as "write
all code". Tests written in bulk test *imagined* behaviour: they verify the shape of things
(signatures, data structures) rather than what a user can do, and they commit you to a test structure
before you understand the implementation.

**Correct approach**: vertical slices via tracer bullets. One test → one implementation → repeat, so
each test responds to what the previous cycle taught you.

```
WRONG (horizontal):          RIGHT (vertical):
  RED:   test1..test5          RED→GREEN: test1→impl1
  GREEN: impl1..impl5          RED→GREEN: test2→impl2
```

## Workflow

### 1. Planning

Before writing any code, have a plan the user approved: the behaviours to test (behaviours, not
implementation steps), in priority order — not everything, the critical paths and complex logic — and
the interface changes they need. Name both in the project's domain glossary vocabulary, consistent with
the ADRs in the area you touch; the interfaces are small, take their dependencies rather than create
them, and return results rather than hide side effects, so the tests can reach them.

**Non-interactive runs.** With no human in the loop — a headless/`-p` invocation, a subagent, or
a program named as your caller — the user's approval cannot be had
and must not be waited on. Treat the task your caller gave as the approved plan, derive
the interface and behaviour list from it, record that list in your notes, and go straight to §2. Never ask a question nobody will read.

### 2. Tracer Bullet

Write ONE test that confirms ONE thing about the system:

```
RED:   Write test for first behavior → test fails
GREEN: Write minimal code to pass → test passes
```

**Before writing any source code: run the test and paste the failure output.** A test that cannot be shown to fail is not a red test. Do not touch source files until you have visible evidence of failure; the one exception is the temporary break below, for code that already exists.

**An edit that is only docs or prompt text** (a README, a SKILL.md) is exempt: no
red test, and no new test — a test that greps that text pins wording, not behaviour.

It must fail **for the intended reason**: on the assertion you wrote, because the behaviour is
absent. An import error, syntax error or broken fixture is not red yet — fix the test until the
assertion is what fails.

**Testing code that already exists** (adding coverage, characterising untested code, pinning a bug
that is already fixed — not changing behaviour): assert the behaviour the code is meant to have, from
its docs, callers and names, not whatever it currently returns.

- It passes on its first run: get the red evidence the other way round. Stage your changes first
  (`git add`, the new test included, since it may share a file with the code), then temporarily
  break the code under test (delete the branch, invert the condition), run the test and paste the
  failure. Restore it with `git checkout -- <file>`, never by hand, and confirm
  `git diff --quiet -- <file>` before you watch the test pass, so the break can never be committed.
- It fails on its assertion: the code contradicts its intended behaviour. Stop: don't change the
  code, since changing behaviour is not this task, and don't write a test that locks the current
  output in. The mismatch is for your caller to act on.

This is your tracer bullet - proves the path works end-to-end.

### 3. Incremental Loop

For each remaining behavior:

```
RED:   Write next test → run it → confirm failure output
GREEN: Minimal code to pass → run it → confirm pass
```

Write only enough code to pass the current test, never for a test you expect to write later.

### 4. Refactor

Once every test passes, leave the code you touched no worse structured than you found it: no
duplication you added, complexity behind small interfaces, tests still on the public interface, and no
abstraction this cycle added that isn't earning its keep (an interface with one implementation, config
for a value that never changes). The tests pass after every refactor step.

**Never refactor while RED.** Get to GREEN first.

## Checklist Per Cycle

```
[ ] Test seen failing on its assertion (for existing code, under the temporary break)
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only
[ ] Test would survive internal refactor
[ ] Code is minimal for this test
[ ] No speculative features added
```
