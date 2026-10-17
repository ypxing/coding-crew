# Host Install

Use this when `INSTALL_MODE=host`.

`PROJECT_ROOT` is **inherited from the caller** — do not re-derive it. Each bash tool call runs in a fresh shell and variables do not persist between calls, so at the top of every bash call assign it to the literal value you were given:

```bash
PROJECT_ROOT="/absolute/path/to/checkout"
```

## Detect and run

`scripts/checks/host-install.sh` ensures `.env` exists (from `.env.example`, or empty if there is none) before it does anything else — the same mechanical step `docker-install.sh` already does via `ensure-env.sh`, now on the host path too. It runs even when no install method is found below, since checks after this step can still need a `.env` to exist. It never reads `.env*` content.

Then it runs the dev commands file's `install` command (dep-install's Step 1 has already made sure
it was asked); when that is `null` or absent, the lockfile's install command (`npm ci`, `uv sync`, …).
Do not look for an install command in `CLAUDE.md`, `AGENTS.md` or the Makefile yourself: discovery
already did.

```bash
bash "<skill-dir>/scripts/checks/host-install.sh" --project-root "$PROJECT_ROOT"
```

Exit codes:
- `0` — install ran successfully
- `2` — no install method found (report blocked)
- other — install command failed (report blocked with verbatim output)

**Notes:**

- `cargo fetch` downloads sources only. If the project requires compiled proc-macro crates before tests run, also run `cargo build --quiet` after `cargo fetch`.
- `mvn dependency:resolve-plugins` ensures build and test plugins are available offline when running `mvn test` or `mvn verify`.

## Rules

- **Always run all commands from `PROJECT_ROOT`**, never from a subdirectory.
- **Never construct binary paths manually** (e.g. `./node_modules/.bin/jest`, `./vendor/bin/phpunit`). Run commands via the ecosystem's standard runner (`npm test`, `go test ./...`, `cargo test`, `pytest`, `bundle exec rspec`) so tool resolution works correctly.
- Run install **once**. Only re-run if you add a new package during implementation.
- Never inject auth tokens or dummy credentials.
- Do not stage or commit lock file changes unless you explicitly added a new package.
- If install fails due to environment issues, stop and report blocked with verbatim output.
