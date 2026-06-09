## Procedure

Implement one issue. One issue in, committed code out.

### Blocked output format

When stopping due to a blocker, always output:

```
BLOCKED: <reason>
<verbatim error or dependency name>
```

Do not attempt workarounds. Do not proceed.

### 0. Pre-flight

Run `git -C "$PROJECT_ROOT" status --short`. If there are modified or staged tracked files not owned by this issue, stop:
`BLOCKED: dirty worktree — stash or commit unrelated changes first`

### 1. Understand the issue

Read the issue file the caller provides — do not query GitHub or any remote tracker.

Extract:
- Acceptance criteria
- Hypothesized files likely to change (confirmed in Step 3)
- Blocked-by dependencies — if any are unresolved, stop and report blocked.

### 2. Install dependencies

#### 2a. Detect install mode

Run this script. It prints `USE_DOCKER` or `USE_HOST`.

```bash
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

# 1. Explicit git config override
_mode=$(git -C "$PROJECT_ROOT" config --local agent.install-mode 2>/dev/null)

# 2. Infer from Makefile public install/deps/setup targets
if [ -z "$_mode" ]; then
  _git_root=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || _git_root=""
  case "$PROJECT_ROOT/" in
    "$_git_root/"*) ;;
    *) _mode="host" ;;
  esac
fi

if [ -z "$_mode" ] && [ -f "$PROJECT_ROOT/Makefile" ]; then
  _uses_docker=$(awk '
    /^[a-zA-Z][a-zA-Z0-9_-]*[[:space:]]*:[^=]/ {
      in_target = ($0 ~ /^(install|deps|setup)[[:space:]]*:/)
    }
    in_target && /^\t/ && /docker[ -]compose|docker compose/ { print "yes"; exit }
  ' "$PROJECT_ROOT/Makefile")
  [ "$_uses_docker" = "yes" ] && _mode="docker"
fi

# 3. Fall back to compose-file presence
if [ -z "$_mode" ]; then
  { [ -f "$PROJECT_ROOT/docker-compose.yml" ] || \
    [ -f "$PROJECT_ROOT/docker-compose.yaml" ] || \
    [ -f "$PROJECT_ROOT/compose.yml" ]; } \
    && _mode="docker" || _mode="host"
fi

[ "$_mode" = "docker" ] && echo "USE_DOCKER" || echo "USE_HOST"
```

Lock this as `INSTALL_MODE` for the entire session — every subsequent command (test, lint, type-check, format, verify) must use the same mode. Do not switch mid-session.

State the mode before continuing:
> "INSTALL_MODE=docker — all subsequent commands run inside docker."
> or
> "INSTALL_MODE=host — all subsequent commands run on the host."

#### 2b. If USE_DOCKER

**Never** run any project command on the host — everything runs inside the container.
**Never** use `docker-compose` (v1 hyphenated) — always use `docker compose` (v2 plugin).
**Always** pass both `-f "$PROJECT_ROOT/docker-compose.yml" -f "$PROJECT_ROOT/docker-compose.override.yml"` on every `docker compose` command after the override file is written.

**Step 1 — Read Makefile and ensure `.env` exists**

Read `$PROJECT_ROOT/Makefile` if present. Scan for targets referencing `.env`, env var names, and targets that generate credential config files (`.npmrc`, `.yarnrc.yml`, etc.) via `envsubst` or template files.

If `.env` does not exist: copy from `.env.example` if it exists, otherwise `touch "$PROJECT_ROOT/.env"`.

If the Makefile has a target that generates a credential config file, run it:
```bash
make -C "$PROJECT_ROOT" <target-name>
```
Or if a `.tpl` file exists with no Makefile target: `envsubst < "$PROJECT_ROOT/<name>.tpl" > "$PROJECT_ROOT/<name>"`

**Never read, log, or print the contents of `.env*` or any credential config file.**

**Step 2 — Read the compose file**

Note:
- The service name (e.g. `app`)
- The container-side source mount path (e.g. `/opt/app`) — call it `CONTAINER_SRC`
- Any environment variable references (e.g. `${MAIN_ROOT}`) — pass each inline on every `docker compose` call

**Step 3 — Derive slug and find vendor directories**

```bash
SLUG=$(basename "$PROJECT_ROOT" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_$//')
```

Find signal files and map each to a named volume. Use the first ecosystem that matches:

- **Node.js** (`package.json` → `node_modules`): find all `package.json` files (excluding `node_modules`), map each to `wt_${SLUG}_nm_${suffix}`
- **Python** (`pyproject.toml` or `requirements.txt` → `.venv`): map to `wt_${SLUG}_venv_${suffix}`
- **Ruby** (`Gemfile` → `vendor/bundle`), **Go** (`go.mod` → `vendor`), **PHP** (`composer.json` → `vendor`), **Rust** (`Cargo.toml` → `target`), **.NET** (`*.csproj` → `obj`, `bin`)

**Step 4 — Write `docker-compose.override.yml`**

Check `IS_SANDBOX`:
```bash
[ "$IS_SANDBOX" = "1" ] && SANDBOX=true || SANDBOX=false
```

If `SANDBOX=true`, add proxy env vars and CA bundle mount. Proxy vars by ecosystem:
- npm/pnpm/bun/yarn: `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, `YARN_HTTPS_PROXY=${HTTPS_PROXY}`
- pip/uv: `HTTPS_PROXY`, `REQUESTS_CA_BUNDLE`
- cargo: `HTTPS_PROXY`, `SSL_CERT_FILE`

CA bundle path: `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu/Alpine) or `/etc/pki/tls/certs/ca-bundle.crt` (RHEL).

Example for Node.js (service `app`, `CONTAINER_SRC=/opt/app`, `SLUG=myproject`):

Non-sandbox:
```yaml
services:
  app:
    volumes:
      - wt_myproject_nm_root:/opt/app/node_modules

volumes:
  wt_myproject_nm_root:
```

Sandbox (Debian base image):
```yaml
services:
  app:
    environment:
      - HTTPS_PROXY
      - NODE_EXTRA_CA_CERTS
      - YARN_HTTPS_PROXY=${HTTPS_PROXY}
    volumes:
      - wt_myproject_nm_root:/opt/app/node_modules
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro

volumes:
  wt_myproject_nm_root:
```

**Step 5 — Run install once**

If the Makefile has a public `install` or `deps` target:
```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$PROJECT_ROOT/docker-compose.override.yml" \
  run --rm <service> make install
```

Otherwise run the package manager directly inside the container:
```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$PROJECT_ROOT/docker-compose.override.yml" \
  run --rm <service> sh -c "cd /opt/app && <install-command>"
```

If the container entrypoint ignores the command, override it with `--entrypoint sh`.

If install fails due to missing auth tokens, network errors, or Docker not running — stop and report blocked with verbatim error.

#### 2c. If USE_HOST

Check in order — use the first match:

1. **CLAUDE.md** — read `$PROJECT_ROOT/CLAUDE.md` if it exists; if it specifies an install command, use that.
2. **Makefile** — check for a public `install` or `deps` target whose recipe does not invoke `docker compose`; if found, run `make -C "$PROJECT_ROOT" install`.
3. **Signal file fallback** — use the first matching file:

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

Rules:
- Always run from `$PROJECT_ROOT`, never a subdirectory.
- Never construct binary paths manually (e.g. `./node_modules/.bin/jest`) — use ecosystem runners (`npm test`, `pytest`, etc.).
- Run install **once**. Only re-run if a new package is added during implementation.
- Never inject auth tokens or dummy credentials.
- Do not stage or commit lock file changes unless you explicitly added a new package.
- If install fails, stop and report blocked with verbatim output.

### 3. Explore before coding

For each hypothesized file from Step 1:
1. Read the source file.
2. Read the corresponding test file if one exists.
3. Note test style, naming conventions, and patterns — this is the style contract for Step 4.

Expand the file list if exploration reveals additional files. Do not guess. Confirm the current state before writing anything.

### 4. Implement with TDD

**Use INSTALL_MODE from Step 2 for all commands.**

Apply **Karpathy guidelines** throughout:
- **Think before coding**: state assumptions explicitly; if multiple interpretations exist, present them; if something is unclear, stop and ask.
- **Simplicity first**: minimum code that solves the problem — no features beyond what was asked, no abstractions for single-use code, no error handling for impossible scenarios.
- **Surgical changes**: touch only what you must; match existing style; every changed line must trace directly to the task.

**TDD workflow** — vertical slices, not horizontal:

```
WRONG: write all tests → write all implementation
RIGHT: test1→impl1, test2→impl2, test3→impl3 (one cycle at a time)
```

For each behavior:
1. **RED** — write one test, run it, paste the failure output. Do not touch source until you have visible failure.
2. **GREEN** — write minimal code to pass. Run the test, confirm it passes.
3. Repeat for the next behavior.
4. **REFACTOR** — after all tests pass, extract duplication, deepen modules. Run tests after each step. Never refactor while RED.

Tests must verify behavior through public interfaces, not implementation details. A test that breaks on internal refactoring (without behavior changing) is a bad test.

### 5. Verify

**Use the same INSTALL_MODE from Step 2.**

Run all project checks and confirm every acceptance criterion is met. To discover checks:
- Look for a `Makefile` with targets like `test`, `lint`, `typecheck`, `check`, `verify`
- Look for scripts in `package.json` (`test`, `lint`, `type-check`)
- Look for `pytest.ini`, `jest.config.*`, `.eslintrc*`, `mypy.ini`

Do not proceed to commit if any check fails or any criterion is unmet.

### 6. Commit

If there are no staged changes after implementation, verify the issue was already done and report accordingly — do not error.

Stage only the files you changed — never `git add .` or `git add -A`.

Commit message format:
```
<issue title>

- <key decision or tradeoff — omit if none>
```

Append the `Co-Authored-By:` trailer specified by the caller as the last line.

Do not push.

**Do not mark the issue done** — the orchestrator handles housekeeping after you return.
