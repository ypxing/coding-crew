# Host Install

Use this when no `docker-compose.yml`, `docker-compose.yaml`, or `compose.yml` exists at `PROJECT_ROOT`.

`PROJECT_ROOT` and `MAIN_ROOT` are established at session startup by the caller. Each bash tool call runs in a fresh shell — variables do not persist between calls. At the top of every bash call, assign both to their literal values from session startup:
```bash
PROJECT_ROOT="/absolute/path/to/worktree"
MAIN_ROOT="/absolute/path/to/main-checkout"
```

## Detect and run

Check in order — use the first match, stop as soon as one is found.

### 1. CLAUDE.md

Read `$PROJECT_ROOT/CLAUDE.md` if it exists. If it specifies an install command, use that.

### 2. Makefile

Check `$PROJECT_ROOT/Makefile` for a public `install` or `deps` target. If one exists and its recipe does not invoke `docker compose`, run it:

```bash
make -C "$PROJECT_ROOT" install
```

### 3. Signal file fallback

No project-specific install found — use the first matching signal file. Run from `$PROJECT_ROOT`.

| Signal file | Install command |
|---|---|
| `uv.lock` | `uv sync --frozen` |
| `bun.lockb` | `bun install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `package-lock.json` | `npm ci` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `poetry.lock` | `poetry install --no-root` |
| `go.sum` / `go.mod` | `go mod download` |
| `requirements.txt` | `pip install -r requirements.txt --quiet` |
| `pyproject.toml` (no lock above) | `pip install --quiet .` |
| `Gemfile.lock` | `bundle install` |
| `Cargo.toml` | `cargo fetch` |
| `composer.json` | `composer install --no-interaction` |
| `pom.xml` | `mvn dependency:resolve dependency:resolve-plugins -q` |
| `*.csproj` | `dotnet restore` |
| `mix.exs` | `mix deps.get` |

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
