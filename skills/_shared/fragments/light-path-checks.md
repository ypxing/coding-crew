1. **Problem** — the source states the problem with its cost or evidence.
2. **One slice** — one vertical slice in the repo you run in looks likely; a plan that changes code in another repo is not one slice.
3. **Criteria** — acceptance criteria are testable, or derivable from the code.
4. **No fork** — no open fork in the "annoyed" lane remains: a decision the user would be annoyed to learn you made without asking — schema, migrations or data model; auth, permissions or PII; anything that costs money or moves scope; user-visible behaviour; breaking an external contract already shipped; conflicting in-repo precedent.
