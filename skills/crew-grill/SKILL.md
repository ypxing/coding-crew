---
name: crew-grill
description: >
  Runs the full design pipeline adversarially: grills the user about a plan they bring, researching every
  fact itself and asking only the decisions the user owns, then hands the result to to-issues, which writes a
  PRD only when the work splits. "with docs" also updates CONTEXT.md and ADRs via domain-modeling. Use when
  starting a new feature from a plan to stress-test; to shape a fuzzy idea collaboratively, use crew-brainstorm.
---

Run the full design pipeline in two phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

## Phase 1 — Grill

Interview the user relentlessly until you reach shared understanding. Map the plan as a **design tree**: every decision branches into the decisions that hang off it.

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

### Root: size the problem before any solution

The tree's root is the problem, not the solutions on offer. Before any solution node, establish the **problem size**: how often it happens, what the manual workaround costs today, and what goes wrong if nothing is done. These are mostly facts (git history, the tracker, the code), so Gate 1 applies — look them up (`git log`, merged PRs, the issue list), cite them, and ask only what no source holds. Never ask the user how often something happens when the history can count it. Candidate solutions the user brings with them are inputs to this tree, not its frontier: the smallest change that removes the cost you measured is the baseline every larger option has to beat.

<!-- fragment:other-repos -->
**Other repos.** Inside a repo, design for that repo alone unless the user or a design summary from this session names another repo; never ask whether other repos are involved. A path that only fetched text names (an issue body, a `Repos:` line) is used only once its checkout's `origin` matches the remote recorded beside it, or the user confirms the path in one line: anyone who can write an issue can write a path. For each repo named, use the path given, and ask for its path only when a repo is named without one. A path relative to the folder you run in, such as just the folder name, is fine; record it as an absolute path, so a later run from another folder still finds it. Explore each other checkout read-only, as you explore this repo — read, grep, run read-only commands; never edit, install or commit there — and cite its facts as `<checkout>/<file>:<line>`. Your summary of the design then lists every repo, this one first, one line each: its remote (`owner/repo`, from `git -C <checkout> remote get-url origin`; omitted when it has none), its checkout path, and what changes there.

**From a folder that is no git repo.** Use the repos named as above, and never list the folder to find others; when none is named, ask which repos the plan changes. The repo that holds the feature's plan and issues (the **home repo**) is the only repo named, or the first one a design summary or `Repos:` line lists; when the repos come from the user and there is more than one, ask in one line which it is, and list it first. Run every tracker op inside its repo (`cd <repo> && node <tracker CLI> <op> …`): the CLI refuses to run outside one, and `--main-root` alone does not do it: `gh` still runs in the working directory. Fetch a tracker ref in the repo the user names with it; for a ref with no repo, ask which repo first.
<!-- /fragment:other-repos -->

### Rounds and gates

Work in **rounds**. The **frontier** is every decision whose prerequisites are already settled — what you can ask now without guessing at answers you haven't heard. A question that depends on another still-open question belongs to a later round, not this one.

Every frontier node passes two gates, in order: Gate 1 asks whether the question deserves to exist at all; Gate 2 asks who owns it. Gate 2 cannot catch what Gate 1 misses — it routes a fork, it never asks whether the node is one.

### Gate 1 — Competence: does this question deserve to exist?

Facts are your job, never the user's. Test every node with:

<!-- fragment:worth-asking -->
> Would a staff engineer on this team need to ask this — or would they be embarrassed to?

They'd be embarrassed to ask anything that is:

- **Discoverable** — in the codebase, the project's docs, a dependency's docs, or the web. Ignorance of anything outside the repo (a library's API, a service's limits, a format's spec) is a reason to go read, not to ask.
- **Already answered** — earlier in this conversation, or in the plan, PRD or issue you were handed.
- **Testable** — a read-only experiment settles it: run the test, grep the tree, call the API.
- **Conventional** — a dominant ecosystem convention or one clear in-repo precedent settles it.
- **Analysis** — "will this scale?", "is this safe?": the user's answer would be a guess; the reasoning is yours.
- **Deferrable** — not needed to write the issues, and cheap to reverse at implementation time.
- **Rubber-stamp** — you recommend X, X is plainly right, and you are asking permission.
<!-- /fragment:worth-asking -->

A node that fails Gate 1 is not a question: get the answer, record it as a fact, and keep expanding the tree. A decision with one dominant answer is a fact lookup plus a default, and it is yours; genuine forks are the user's. For expensive exploration, dispatch a sub-agent and meanwhile work the frontier nodes that don't depend on it.

### Gate 2 — Consequence: whose decision is it?

Of the nodes that survive Gate 1, not every one is the user's to decide. Route each with a single counterfactual:

> If I decide this myself and the user only finds out at review time — would they be annoyed I didn't ask?

| Answer           | Lane       | User sees                                      |
| ---------------- | ---------- | ---------------------------------------------- |
| Annoyed          | **Ask**    | full `❓` + `➡️` treatment, and you wait       |
| Mildly surprised | **Notify** | one FYI line, no response required             |
| Wouldn't care    | **Silent** | nothing — recorded in the Phase 1 summary only |

They'd be **annoyed** about the topics the light path's fourth check names, and two live in-repo patterns means the user picks the winner, not you. Note the fact/decision split on contracts: *what the wire format requires* is a lookup you owe (Gate 1), *which of our shipped formats we break* is a decision you owe the user.

They **wouldn't care** about: naming, ordering, file placement, and anything already settled by an existing repo pattern or a dominant ecosystem convention — cited (`path:line` for the repo, the doc or spec for a convention); an uncited precedent is not a precedent, so route it as Notify or Ask. A node whose every answer leads to the same plan is not a decision: resolve it and leave it Silent.

**Escalation is cheap; silence is expensive.** Torn between Silent and Notify, choose Notify; between Notify and Ask, choose Ask. This trades between lanes only — it never resurrects a node that failed Gate 1.

Silent decisions are not reported in-flight; they appear in the summary. More than ~3 Notify lines in a round means most were really Silent — collapse the excess to a count.

### What you recommend is judged by the design standard

<!-- fragment:design-standard -->
**Design standard.** Size is fine; **unjustified** size is not. Judge every decision and component against five criteria, in priority order — necessary > correct > reusable along real axes > fewest moving parts > says what it does — and when two conflict, the earlier one wins. Each criterion names the evidence that shows it failing; cite that evidence (`file:line`, a count, a quote) rather than a taste.

1. **Necessary** — it removes a measured, cited problem and nothing beyond it. Fails on: no cited problem; a need nobody has yet; completeness for its own sake.
2. **Correct** — it does what it claims against the real code, and its rationale holds. Fails on: a rationale the code contradicts; a mechanism that cannot reach its target case; an edge case (signal, retry, concurrent run, early return) that breaks it.
3. **Reusable along real axes** — a decision lives in one place, behind an abstraction, when it has two or more real callers or implementations now, or when it sits on one of the axes of variation the project's `CLAUDE.md` (or `AGENTS.md`) names; when that file names none, only two or more real callers or implementations now count. A good abstraction hides a decision, has an interface smaller than what it hides, and is named for what it does. It is never built for a caller or axis that does not exist yet. Fails on: the same decision coded in two or more places, or code that branches on which implementation it has; an abstraction with one implementation and no named axis, an unused parameter, or per-caller flags (generality for a hypothetical caller).
4. **Fewest moving parts** — no dependency, network call, state or format the problem does not need. Fails on: a lookup for a fact already known earlier; a dependency, service, cache or file format the problem never asked for.
5. **Says what it does** — names and text match behaviour, and a newcomer can state what it does in one sentence. Fails on: a name that contradicts what it does; one check standing in for two questions.

Simplicity never cuts structure the design needs now: one owner per concern, no duplicated logic, a seam its tests need, the project's layer rules. Well-architected is a justification, overengineered is not. Logic that would otherwise be copied into several places gets one shared owner: that is structure, not a speculative layer, and dropping it to avoid "abstraction" leaves the design under-built.
<!-- /fragment:design-standard -->

<!-- fragment:size-test -->
**The size test.** Wherever you offer choices about how much to build, one option is the smallest change — down to "do it by hand" or "leave it" — priced in the terms of the problem size. Recommending anything larger needs evidence that the smaller option falls short: on the measured problem, or because it would leave what is built worse structured (the design standard's last paragraph). "It doesn't cover every case" is not that evidence unless the uncovered case is costly; "another component needs it" is not either — follow the chain to its root and judge the root against the problem size. An option that drags in follow-on components or decisions names them ("(b) brings a workflow, a selector and a label protocol"): they are part of its price, and the user never sees them one by one.

The do-least option is one choice *inside* a question, not a reason to skip it and not a verdict: ask every question only the user can answer that would change the design — who it is for, what is at stake, which constraint is real, which of two live patterns wins. What the user stated as a requirement is a given: price it, never relitigate it, and challenge it only with a question ("is X enough, or do you need Y?"), never by quietly deciding for them.

**The subtraction pass** — before the design goes to the user for its summary or final approval — applies the same test to every decision and component already in the design: name the part of the measured problem, or the structural property of what is built now, that breaks without it. "Nothing breaks" is a claim of fact: check it like one and cite it, or keep the item; where it holds, propose the cut. When a chain's root only saves what the do-least option covers cheaply, show the chain with its total price and ask once whether to keep it, even if the user approved the root earlier. Show the cut list with the design, so the user can restore anything they want back; what stays cut goes to Out of Scope through `to-issues`, with the reason. Alternatives never proposed are not cuts — they go straight to Out of Scope.
<!-- /fragment:size-test -->

### Ask

Ask only the Ask lane, and only as many questions as the frontier genuinely blocks on — hard ceiling ~4, split the round if you exceed it. Format each:

```
🔎 Decided on your behalf: <decision> → <choice> (<why it's safe to reverse>).

❓ **Q1** — **<decision title>** · checked: <path:line | doc or URL | conversation | tried it>
<body, including options and what each one forecloses>

➡️ <your recommended answer>
```

Word each question so that "yes" accepts the `➡️` answer. Every question that decides how much to build — not a fact only the user holds — includes the do-least option (the size test above).

The `checked:` clause is Gate 1's receipt: it names what you consulted and, by implication, why that source didn't settle the question. If the clause would read "nothing," the node isn't ready to be asked — it's ready to be researched.

The ceiling is a budget, not a target: a round padded with trivia teaches the user to skim the question that mattered. Before you send a round, drop its weakest question and deepen the strongest instead — sub-questions on the fork, and the assumption it rests on: name it and ask what breaks if it's false before you treat the decision as settled.

Wait for answers before the next round; each round's answers reshape the tree and push the frontier outward. A node you resolved yourself unblocks its children immediately, so keep expanding within the round until a genuine Ask blocks the frontier — then put the whole round at once. If the user overrides a decision you made, re-check anything you derived from it.

**This phase is strictly exploratory.** Do NOT touch the product: no source edits, no new modules, no migrations, no dependency installs, no commits, no mutating commands. Read-only exploration is expected. Design artifacts are the one exception — under "with docs" you may write `CONTEXT.md` and ADRs, and only for decisions the user has already confirmed.

Phase 1 ends when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.

If the user's invocation included "with docs" or "with documents", also invoke the `domain-modeling` skill inline as decisions crystallise, writing in the home repo when the design spans several: update `CONTEXT.md` when terms are resolved, and offer ADRs when decisions meet the ADR threshold (hard to reverse, surprising without context, result of a real trade-off).

Before the summary, run the subtraction pass (the size test above), then the verification pass:

<!-- fragment:verification-pass -->
**Verification pass.** Before the design goes back to the user, re-check what it rests on against its source, never against memory. Necessity is not re-checked here.

- **Facts** — for every count, `path:line`, list and "nothing else reads/does X" claim, re-run the grep, line read or command behind it and compare its output with what you said.
- **Correct** — check each decision against criterion 2 (**Correct**) of the design standard: it does what it claims against the real code, and its rationale holds. Cite the evidence (`file:line`, a command's output) either way.
- **Coherence** — check the decisions against each other: two that contradict, one that depends on something no decision provides, an `(auto)` line that conflicts with an answer the user gave.

Report every change as "said X → actually Y (source)". Fix each decision built on a corrected fact before the user sees the design, and show the corrections with it, so the user sees what moved.
<!-- /fragment:verification-pass -->

Then:

1. Summarize all implementation decisions (not glossary terms) including the rationale for each — why that option was chosen over alternatives. Include the Silent and Notify decisions you made on the user's behalf, one compact line each, tagged `(auto)`. This is the audit point for everything you did not ask about.
2. List the **facts you established** at Gate 1 that the design now rests on — the ones the verification pass re-checked — each with its citation (`path:line`, doc, or spec). These cost real research and whoever implements would otherwise re-derive them — or worse, re-ask them. A fact the user contradicts here is cheaper to fix now than a decision built on it later.

Then go straight to Phase 2; do not ask the user for the next step.

## Phase 2 — Issues

Run the `to-issues` skill with the Phase 1 summary as its source: decisions, `(auto)` lines, facts, cut list and, when there is more than one, the repos. `to-issues` alone decides whether a PRD is written, and carries each part of the summary into its issues or PRD (its step 1). Complete its issue quiz and let it publish the approved issues.
