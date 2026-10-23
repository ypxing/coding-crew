# Host Install

Use this when `INSTALL_MODE=host`. `PROJECT_ROOT` is **inherited from the caller** — do not re-derive it.
Each bash call is a fresh shell, so write its literal value into every call.

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/host-install.sh" --project-root "$PROJECT_ROOT"
```

It makes sure `.env` exists (never reading `.env*` content), runs the dev commands file's `registry_auth`
command if any, then its `install` command, or the lockfile's own (`npm ci`, `uv sync`, …) when `install`
is `null` or absent. Dep-install's Step 1 has already made sure `install` was asked: do not look for an
install command in `CLAUDE.md`, `AGENTS.md` or the Makefile yourself.

Exit codes:
- `0` — install ran successfully
- `2` — no install method found (report blocked)
- other — install command failed (report blocked with verbatim output)

## Rules

- Every command runs from `PROJECT_ROOT`, through the ecosystem's standard runner (`npm test`, `go test ./...`,
  `cargo test`, `pytest`, `bundle exec rspec`), never a binary path you built (`./node_modules/.bin/jest`).
- Install runs **once**; again only after you add a package.
- `cargo fetch` downloads sources only: when the tests need compiled proc-macro crates, also run
  `cargo build --quiet`.
- Never inject auth tokens or dummy credentials.
- Lockfile changes are staged or committed only when you added a package.
