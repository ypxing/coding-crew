---
name: crew-brainstorm
description: >
  Agrees a design with the user collaboratively before implementation: explores intent one question at a
  time, proposes 2-3 approaches, and gets the design approved section by section, then hands off to
  to-issues. Use when starting a complex or exploratory feature from a fuzzy idea; to stress-test a plan you
  already have adversarially, use crew-grill.
---

# Brainstorming Ideas Into Designs

Help turn ideas into fully formed designs through natural collaborative dialogue.

Start by understanding the current project context. If the source already passes the four light-path checks, hand it to `to-issues`; otherwise ask questions one at a time to refine the idea, and once you understand what you're building, present the design and get user approval.

<HARD-GATE>
Do NOT invoke any implementation skill, write any code, scaffold any project, or take any implementation action until the design is settled: either you presented it and the user approved it, or the source passed all four light-path checks and went to `to-issues`, whose quiz is the single review. Nothing else skips the design.
</HARD-GATE>

## Anti-Pattern: "This Is Too Simple To Need A Design"

"Simple" is not the exemption; only the four light-path checks are. A todo list, a single-function utility, a config change: "simple" projects are where unexamined assumptions cause the most wasted work. The design can be short (a few sentences for truly simple projects), but it is presented and approved.

## Checklist

Complete these in order:

1. **Explore project context** — check files, docs, recent commits
2. **Judge the light path** — if the source is already one complete change, skip to step 6
3. **Ask clarifying questions** — one at a time; size the problem first, then purpose, constraints and success criteria
4. **Propose 2-3 approaches** — with trade-offs and your recommendation; one is always the do-least option
5. **Present design** — in sections scaled to their complexity, get user approval after each section
6. **Hand off** — invoke `to-issues`, passing the agreed design (decisions, `(auto)` lines, facts, cut list)

## The Process

{{FRAGMENT:light-path}}

### Understanding the idea

- Check out the current project state first (files, docs, recent commits)
- Before asking detailed questions, assess scope: if the request describes multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), flag this immediately. Don't spend questions refining details of a project that needs to be decomposed first.
- If the project is too large for a single spec, help the user decompose into sub-projects: what are the independent pieces, how do they relate, what order should they be built? Then brainstorm the first sub-project through the normal design flow. Each sub-project gets its own pass through `to-issues`.
- For appropriately-scoped projects, ask questions one at a time to refine the idea
- Each question carries options and your recommended answer. An open question is for when the user has not found the words yet: their own description carries intent your options can't.
- Only one question per message - if a topic needs more exploration, break it into multiple questions
- Ground to cover — territory, not a script; never read these out as questions: purpose, constraints, success criteria, and anti-goals (what would make this a failure even if it technically works)
- Size the problem before any solution: how often it happens, what the manual workaround costs today, and what goes wrong if nothing is done. Look these up (git history, the tracker, the code) before asking. Solutions the user arrives with are inputs, not the menu.

### Exploring approaches

Propose 2-3 different approaches with trade-offs, conversationally, leading with your recommended option and why. One of them is always the do-least option:

{{FRAGMENT:size-test}}

What you recommend is judged by the design standard:

{{FRAGMENT:design-standard}}

### Presenting the design

- Once you believe you understand what you're building, present the design
- Scale each section to its complexity: a few sentences if straightforward, up to 200-300 words if nuanced
- Ask after each section whether it looks right so far
- Cover: architecture, components, data flow, error handling, testing
- Every default you chose is marked as yours, tagged `(auto)`, never written as something the user agreed to: a default they never heard is one they couldn't reject. Only what they said goes in as theirs.
- Be ready to go back and clarify if something doesn't make sense
- Before asking for final approval, run the subtraction pass (the size test above), then the verification pass:

{{FRAGMENT:verification-pass}}

- Then ask for final approval of the whole design, showing what you cut and every correction the verification pass made

### Design for isolation and clarity

- Break the system into smaller units that each have one clear purpose, communicate through well-defined interfaces, and can be understood and tested independently
- For each unit, you should be able to answer: what does it do, how do you use it, and what does it depend on?
- Can someone understand what a unit does without reading its internals? Can you change the internals without breaking consumers? If not, the boundaries need work.

### Working in existing codebases

- Explore the current structure before proposing changes. Follow existing patterns.
- Where existing code has problems that affect the work (e.g., a file that's grown too large, unclear boundaries, tangled responsibilities), include targeted improvements as part of the design - the way a good developer improves code they're working in.
- Don't propose unrelated refactoring. Stay focused on what serves the current goal.

## After the Design

Once the user approves the design, invoke `to-issues`, passing the agreed decisions, the `(auto)` lines, facts and cut list. `to-issues` alone decides whether a PRD is written and what the slug is; do not ask the user for either.

- Do NOT invoke any other skill. `to-issues` is the only path forward.
