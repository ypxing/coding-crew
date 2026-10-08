---
name: tdd
description: Test-driven development with red-green-refactor loop. Use when user wants to build features or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first development.
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

When exploring the codebase, use the project's domain glossary so that test names and interface vocabulary match the project's language, and respect ADRs in the area you're touching.

Before writing any code:

- [ ] Confirm with user which interface changes are needed and which behaviours to test, in priority order — you can't test everything, so focus on critical paths and complex logic, and get approval on that plan
- [ ] Identify opportunities for deep modules (see `references/deep-modules.md` alongside this skill file)
- [ ] Design interfaces for testability (see `references/interface-design.md` alongside this skill file)
- [ ] List the behaviors to test (not implementation steps)

**Non-interactive runs.** With no human in the loop — `CREW_ORCHESTRATED=1`, a headless/`-p`
invocation, or an orchestrator named as your caller — the confirm-and-approve box cannot be
satisfied and must not be waited on. Treat the issue's acceptance criteria as the approved plan,
derive the interface and behaviour list from them, record that list in your notes, and go straight
to §2. Never ask a question nobody will read.

**Bug fixes.** Skip the interface-design boxes: find the existing test closest to the broken
codepath, and write there the smallest test that would have caught the bug, asserting the intended
behaviour. It is your tracer bullet; §2 applies unchanged. A flaky bug needs a deterministic test —
pin the clock, seed or ordering the flake depends on. If it passes on its first run, through the path
the bug report names, stop: that result is for your caller to act on. Don't rewrite the test until it
fails. If it is kept as a regression test, get its red as for code that already exists (§2).

**When no practical test exists.** Prefer no new test over a bad one — one that mostly tests mocks,
encodes implementation details, or depends on timing or global state. Only then, use the closest
executable check instead (a reproduction command, a targeted script, a log assertion), run it before
and after the change, and record why no test path exists. Being slow to write is not a reason, and
the fallback never replaces a test the task explicitly asks for.

### 2. Tracer Bullet

Write ONE test that confirms ONE thing about the system:

```
RED:   Write test for first behavior → test fails
GREEN: Write minimal code to pass → test passes
```

**Before writing any source code: run the test and paste the failure output.** A test that cannot be shown to fail is not a red test. Do not touch source files until you have visible evidence of failure; the one exception is the temporary break below, for code that already exists.

It must fail **for the intended reason**: on the assertion you wrote, because the behaviour is
absent. An import error, syntax error or broken fixture is not red yet — fix the test until the
assertion is what fails.

**Testing code that already exists** (adding coverage, characterising untested code): the test
passes on its first run, so get the red evidence the other way round. Temporarily break the code
under test (delete the branch, invert the condition), run the test and paste the failure. Commit your
changes first (the new test included, since it may share a file with the code), so the break is the
only uncommitted change, and restore it with `git checkout -- <file>`, never by hand. Confirm `git diff --quiet -- <file>` before you watch the test pass, so the break can never be
committed. Assert the behaviour the code is meant to have, from its docs, callers and names, not
whatever it currently returns. When the current output contradicts that, stop, and don't write a
test that locks it in: the mismatch is for your caller to act on.

This is your tracer bullet - proves the path works end-to-end.

### 3. Incremental Loop

For each remaining behavior:

```
RED:   Write next test → run it → confirm failure output
GREEN: Minimal code to pass → run it → confirm pass
```

Rules:

- One test at a time
- Run the test after writing it — paste the failure before touching source
- Only enough code to pass current test
- Don't anticipate future tests
- Keep tests focused on observable behavior
- Never edit a test to match a wrong implementation, and never weaken an existing assertion unless
  the intended behaviour changed and you can say how

### 4. Refactor

After all tests pass, look for refactor candidates (see `references/refactoring.md` alongside this skill file):

- [ ] Extract duplication
- [ ] Deepen modules (move complexity behind simple interfaces)
- [ ] Apply SOLID principles where natural
- [ ] Consider what new code reveals about existing code
- [ ] Remove any abstraction this cycle added that isn't earning its keep (interface with one implementation, config for a value that never changes)
- [ ] Run tests after each refactor step

**Never refactor while RED.** Get to GREEN first.

## Checklist Per Cycle

```
[ ] Test failed on its assertion before the code made it pass
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only
[ ] Test would survive internal refactor
[ ] Code is minimal for this test
[ ] No speculative features added
```
