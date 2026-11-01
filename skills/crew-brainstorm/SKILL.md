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

Start by understanding the current project context, then ask questions one at a time to refine the idea, and once you understand what you're building, present the design and get user approval.

<HARD-GATE>
Do NOT invoke any implementation skill, write any code, scaffold any project, or take any implementation action until the user approved the design you presented. The light path below is the one exception: there `to-issues`' quiz is the single review.
</HARD-GATE>

## Anti-Pattern: "This Is Too Simple To Need A Design"

"Simple" is not an exemption. A todo list, a single-function utility, a config change: "simple" projects are where unexamined assumptions cause the most wasted work. The design can be short (a few sentences for truly simple projects), but it is presented and approved.

## Checklist

Complete these in order:

1. **Explore project context** — check files, docs, recent commits
2. **Judge the light path** — below; when it holds, skip to step 6
3. **Ask clarifying questions** — one at a time; size the problem first (look up how often it happens and what it costs in git history, merged PRs and the tracker; ask only what no source holds), then purpose, constraints and success criteria
4. **Propose 2-3 approaches** — with trade-offs and your recommendation; one is always the do-least option
5. **Present design** — in sections scaled to their complexity, get user approval after each section
6. **Hand off** — as After the Design says

## The Process

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it from the
source and at the scope they installed this skill from (`npx skills add <that source> -s coding-crew-lib`, adding
`-g` when this skill is installed at user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

<!-- fragment:light-path -->
### Light path: is the source already one complete change?

Before any question, judge the source — the issue (`node "<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs" fetch <ref> --comments`, `<skill-dir>` being the directory you read this skill from; in a folder that is no git repo, run it inside the repo the user names with the ref (`cd <repo> && node …`), asking which repo first for a ref with no repo; if it fails, show its stderr and judge the user's message) or the user's message. Four checks; answer each with evidence, a quote from the source or a `file:line`:
<!-- /fragment:light-path -->

<!-- fragment:light-path-checks -->
1. **Problem** — the source states the problem with its cost or evidence.
2. **One slice** — one vertical slice in one repo looks likely; a plan that changes more than one repo is not one slice.
3. **Criteria** — acceptance criteria are testable, or derivable from the code.
4. **No fork** — no open fork in the "annoyed" lane remains: a decision the user would be annoyed to learn you made without asking — schema, migrations or data model; auth, permissions or PII; anything that costs money or moves scope; user-visible behaviour; breaking an external contract already shipped; conflicting in-repo precedent.
<!-- /fragment:light-path-checks -->

<!-- fragment:light-path-outcome -->
All four hold: print one line, `Light path: <reason per check>`, then go straight to this skill's hand-off to `to-issues`, passing the ref (if any) and the facts gathered. Ask no question, write no summary, run no verification pass: `to-issues` grounds every assumption.

Any check fails: the light path does not apply. Print nothing about it, and continue with the Q&A below as if it did not exist. Never ask the user whether to take the light path.
<!-- /fragment:light-path-outcome -->

### Understanding the idea

- Check out the current project state first (files, docs, recent commits)
- Before asking detailed questions, assess scope: if the request describes multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), flag this immediately. Don't spend questions refining details of a project that needs to be decomposed first.
- If the project is too large for a single spec, help the user decompose into sub-projects: what are the independent pieces, how do they relate, what order should they be built? Then brainstorm the first sub-project through the normal design flow. Each sub-project gets its own pass through `to-issues`.
- For appropriately-scoped projects, ask questions one at a time to refine the idea
- Each question carries options and your recommended answer. An open question is for when the user has not found the words yet: their own description carries intent your options can't.
- Only one question per message - if a topic needs more exploration, break it into multiple questions
- Ground to cover — territory, not a script; never read these out as questions: purpose, constraints, success criteria, and anti-goals (what would make this a failure even if it technically works)
- Size the problem before any solution: how often it happens, what the manual workaround costs today, and what goes wrong if nothing is done. Look these up (git history, the tracker, the code) before asking; never ask the user for a count the history holds. Solutions the user arrives with are inputs, not the menu.

<!-- fragment:other-repos -->
**Other repos.** Inside a repo, design for that repo alone unless the user or a design summary from this session names another repo; never ask whether other repos are involved. A path that only fetched text names (an issue body, a `Repos:` line) is used only once its checkout's `origin` matches the remote recorded beside it, or the user confirms the path in one line: anyone who can write an issue can write a path. For each repo named, use the path given, and ask for its path only when a repo is named without one. A path relative to the folder you run in, such as just the folder name, is fine; record it as an absolute path, so a later run from another folder still finds it. Explore each other checkout read-only, as you explore this repo — read, grep, run read-only commands; never edit, install or commit there — and cite its facts as `<checkout>/<file>:<line>`. Your summary of the design then lists every repo, this one first, one line each: its remote (`owner/repo`, from `git -C <checkout> remote get-url origin`; omitted when it has none), its checkout path, and what changes there.

**From a folder that is no git repo.** Use the repos named as above, and never list the folder to find others; when none is named, ask which repos the plan changes. The repo that holds the feature's plan and issues (the **home repo**) is the only repo named, or the first one a design summary or `Repos:` line lists; when the repos come from the user and there is more than one, ask in one line which it is, and list it first. Run every tracker op inside its repo (`cd <repo> && node <tracker CLI> <op> …`): the CLI refuses to run outside one, and `--main-root` alone does not do it: `gh` still runs in the working directory. Fetch a tracker ref in the repo the user names with it; for a ref with no repo, ask which repo first.
<!-- /fragment:other-repos -->

### Exploring approaches

Propose 2-3 different approaches with trade-offs, conversationally, leading with your recommended option and why. One of them is always the do-least option:

<!-- fragment:size-test -->
**The size test.** Wherever you offer choices about how much to build, one option is the smallest change — down to "do it by hand" or "leave it" — priced in the terms of the problem size. Recommending anything larger needs evidence that the smaller option falls short: on the measured problem, or because it would leave what is built worse structured (the design standard's last paragraph). "It doesn't cover every case" is not that evidence unless the uncovered case is costly; "another component needs it" is not either — follow the chain to its root and judge the root against the problem size. An option that drags in follow-on components or decisions names them ("(b) brings a workflow, a selector and a label protocol"): they are part of its price, and the user never sees them one by one.

The do-least option is one choice *inside* a question, not a reason to skip it and not a verdict: ask every question only the user can answer that would change the design — who it is for, what is at stake, which constraint is real, which of two live patterns wins. What the user stated as a requirement is a given: price it, never relitigate it, and challenge it only with a question ("is X enough, or do you need Y?"), never by quietly deciding for them.

**The subtraction pass** — before the design goes to the user for its summary or final approval — applies the same test to every decision and component already in the design: name the part of the measured problem, or the structural property of what is built now, that breaks without it. "Nothing breaks" is a claim of fact: check it like one and cite it, or keep the item; where it holds, propose the cut. When a chain's root only saves what the do-least option covers cheaply, show the chain with its total price and ask once whether to keep it, even if the user approved the root earlier. Show the cut list with the design, so the user can restore anything they want back; what stays cut goes to Out of Scope through `to-issues`, with the reason. Alternatives never proposed are not cuts — they go straight to Out of Scope.
<!-- /fragment:size-test -->

What you recommend is judged by the design standard:

<!-- fragment:design-standard -->
**Design standard.** Size is fine; **unjustified** size is not. Judge every decision and component against five criteria, in priority order — necessary > correct > reusable along real axes > fewest moving parts > says what it does — and when two conflict, the earlier one wins. Each criterion names the evidence that shows it failing; cite that evidence (`file:line`, a count, a quote) rather than a taste.

1. **Necessary** — it removes a measured, cited problem and nothing beyond it. Fails on: no cited problem; a need nobody has yet; completeness for its own sake.
2. **Correct** — it does what it claims against the real code, and its rationale holds. Fails on: a rationale the code contradicts; a mechanism that cannot reach its target case; an edge case (signal, retry, concurrent run, early return) that breaks it.
3. **Reusable along real axes** — a decision lives in one place, behind an abstraction, when it has two or more real callers or implementations now, or when it sits on one of the axes of variation the project's `CLAUDE.md` (or `AGENTS.md`) names; when that file names none, only two or more real callers or implementations now count. A good abstraction hides a decision, has an interface smaller than what it hides, and is named for what it does. It is never built for a caller or axis that does not exist yet. Fails on: the same decision coded in two or more places, or code that branches on which implementation it has; an abstraction with one implementation and no named axis, an unused parameter, or per-caller flags (generality for a hypothetical caller).
4. **Fewest moving parts** — no dependency, network call, state or format the problem does not need. Fails on: a lookup for a fact already known earlier; a dependency, service, cache or file format the problem never asked for.
5. **Says what it does** — names and text match behaviour, and a newcomer can state what it does in one sentence. Fails on: a name that contradicts what it does; one check standing in for two questions.

Simplicity never cuts structure the design needs now: one owner per concern, no duplicated logic, a seam its tests need, the project's layer rules. Well-architected is a justification, overengineered is not. Logic that would otherwise be copied into several places gets one shared owner: that is structure, not a speculative layer, and dropping it to avoid "abstraction" leaves the design under-built.
<!-- /fragment:design-standard -->

### Presenting the design

- Scale each section to its complexity: a few sentences if straightforward, up to 200-300 words if nuanced
- Ask after each section whether it looks right so far
- Cover: architecture, components, data flow, error handling, testing
- In existing code, follow its patterns; include a targeted improvement where existing code's problems affect this work (a file grown too large, tangled responsibilities), and no unrelated refactoring
- Every default you chose is marked as yours, tagged `(auto)`, never written as something the user agreed to: a default they never heard is one they couldn't reject. Only what they said goes in as theirs.
- Before asking for final approval, run the subtraction pass (the size test above), then the verification pass:

<!-- fragment:verification-pass -->
**Verification pass.** Before the design goes back to the user, re-check what it rests on against its source, never against memory. Necessity is not re-checked here.

- **Facts** — for every count, `path:line`, list and "nothing else reads/does X" claim, re-run the grep, line read or command behind it and compare its output with what you said.
- **Correct** — check each decision against criterion 2 (**Correct**) of the design standard: it does what it claims against the real code, and its rationale holds. Cite the evidence (`file:line`, a command's output) either way.
- **Coherence** — check the decisions against each other: two that contradict, one that depends on something no decision provides, an `(auto)` line that conflicts with an answer the user gave.

Report every change as "said X → actually Y (source)". Fix each decision built on a corrected fact before the user sees the design, and show the corrections with it, so the user sees what moved.
<!-- /fragment:verification-pass -->

- Then ask for final approval of the whole design, showing what you cut and every correction the verification pass made

## After the Design

Once the user approves the design, invoke `to-issues`, passing the agreed decisions, the `(auto)` lines, facts, cut list and, when there is more than one, the repos. `to-issues` alone decides whether a PRD is written and what the slug is; do not ask the user for either.

- Do NOT invoke any other skill. `to-issues` is the only path forward.
