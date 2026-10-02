# Wide refactors: expand–contract

Read this when step 4's slicing meets a wide refactor.

**Wide refactors are the exception to vertical slicing.** A wide refactor is one mechanical change — rename a column, retype a shared symbol — whose blast radius fans across the whole codebase so no vertical slice can land green on its own. Don't force it into a tracer bullet; sequence it as **expand–contract**:

1. **Expand** — add the new form beside the old so nothing breaks
2. **Migrate** — move call sites over in batches (per package, per directory), each batch its own issue blocked by the expand, keeping CI green batch to batch because the old form still exists
3. **Contract** — delete the old form once no caller remains, blocked by every migrate batch

When migrate batches cannot each pass the checks alone, and together they fit one fresh context window, write them as one issue — a single landable slice.

Otherwise write one `Status: ready-for-human` issue whose `### Why a person` says the batches cannot land green one at a time under crew-afk's per-branch verify. Never write an issue that only goes green after others merge.
