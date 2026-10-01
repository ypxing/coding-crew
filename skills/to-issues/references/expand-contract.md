# Wide refactors: expand–contract

Read this when step 4's slicing meets a wide refactor.

**Wide refactors are the exception to vertical slicing.** A wide refactor is one mechanical change — rename a column, retype a shared symbol — whose blast radius fans across the whole codebase so no vertical slice can land green on its own. Don't force it into a tracer bullet; sequence it as **expand–contract**:

1. **Expand** — add the new form beside the old so nothing breaks
2. **Migrate** — move call sites over in batches (per package, per directory), each batch its own issue blocked by the expand, keeping CI green batch to batch because the old form still exists
3. **Contract** — delete the old form once no caller remains, blocked by every migrate batch

When even the batches can't stay green independently, let them share an integration branch and block a final integrate-and-verify issue — green is promised only there.
