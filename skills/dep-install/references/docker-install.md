# Docker Install

Use this when `docker-compose.yml`, `docker-compose.yaml`, or `compose.yml` exists at `PROJECT_ROOT`.
Do **not** run any command on the host — everything runs inside the container.

`PROJECT_ROOT` and `MAIN_ROOT` are established at session startup by the caller. Each bash tool call runs in a fresh shell — variables do not persist between calls. At the top of every bash call, assign both to their literal values from session startup:

```bash
PROJECT_ROOT="/absolute/path/to/worktree"
MAIN_ROOT="/absolute/path/to/main-checkout"
```

## Never

- Never run any install or project command on the host — everything runs inside the container.
- Never use `docker-compose` (v1 hyphenated binary) — always use `docker compose` (v2 plugin).
- Always pass both `-f "$PROJECT_ROOT/docker-compose.yml" -f "$PROJECT_ROOT/docker-compose.override.yml"` on every `docker compose` command after step 3.

## Steps

### 0. Read Makefile and ensure `.env` exists

**a. Read the Makefile** (`$PROJECT_ROOT/Makefile`), if present. Scan for:

- Targets that reference `.env` (e.g. `cp .env.example .env`, `$(MAKE) .env`)
- Environment variable names used in recipes (e.g. `$(NPM_TOKEN)`, `export FOO`)
- Any comments describing required secrets or setup
- Targets that generate package-manager credential config files (e.g. `.npmrc`, `.yarnrc.yml`, `pip.conf`, `.cargo/credentials.toml`) via `envsubst`, `echo`, or template files (`.npmrc.tpl`, `pip.conf.tpl`, etc.)

This step is always done — the Makefile reveals how the project works and what env vars are expected.

**b. If `.env` does not exist at `PROJECT_ROOT`:**

- If `.env.example` exists: `cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"`
- Otherwise: `touch "$PROJECT_ROOT/.env"`

**c. Generate credential config files if the Makefile has a target for them:**

- If a Makefile target generates a package-manager credential config file (identified in step a), run that target:
  ```bash
  make -C "$PROJECT_ROOT" <target-name>
  ```
- If no Makefile target exists but a `.tpl` file is present (e.g. `.npmrc.tpl`, `pip.conf.tpl`), generate via `envsubst`:
  ```bash
  envsubst < "$PROJECT_ROOT/<name>.tpl" > "$PROJECT_ROOT/<name>"
  ```
- Skip silently if neither exists.

**d.** Log what was done (e.g. "Created .env from .env.example; generated .npmrc from Makefile target").

**Never read the contents of `.env*` or any credential config file** — not to log, not to inspect, not to verify.

Always continue to step 1 — this step never blocks. If `docker compose` later fails because a required env var is missing, stop and report blocked with the verbatim error.

### 1. Read the compose file

Note:

- The service name (e.g. `app`)
- The container-side source mount path (e.g. `/opt/app`) — call it `CONTAINER_SRC`
- Any environment variable references in the file (e.g. `${MAIN_ROOT}`, `${APP_ROOT}`) — pass each one inline on every `docker compose` call

### 2. Derive slug and find all vendor directories

```bash
SLUG=$(basename "$PROJECT_ROOT" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_$//')
```

Named volumes scoped to this worktree's slug shadow the bind-mount at vendor paths so each worktree gets its own isolated, clean directory. Docker named volumes always start empty, so **install must always run inside the container** regardless of whether vendor directories exist on the host.

Find signal files and map each to a named volume. Use the first ecosystem that matches; if multiple signal files are present, use the one that corresponds to the primary language.

**Node.js** (`package.json` -> `node_modules`):

```bash
find "$PROJECT_ROOT" -name 'package.json' \
  -not -path '*/node_modules/*' \
  -maxdepth 5 \
  | while read -r pkg; do
      dir=$(dirname "$pkg")
      rel=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1],sys.argv[2]))" "$dir" "$PROJECT_ROOT")
      [ "$rel" = "." ] \
        && container_path="$CONTAINER_SRC/node_modules" \
        || container_path="$CONTAINER_SRC/$rel/node_modules"
      suffix=$(echo "$rel" | tr '/.-' '___' | sed 's/^\.$/root/')
      echo "volume: wt_${SLUG}_nm_${suffix}  ->  ${container_path}"
    done
```

**Python** (`pyproject.toml` or `requirements.txt` -> `.venv`):

```bash
find "$PROJECT_ROOT" -maxdepth 3 \
  \( -name 'pyproject.toml' -o -name 'requirements.txt' \) \
  -not -path '*/.venv/*' \
  | while read -r f; do
      dir=$(dirname "$f")
      rel=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1],sys.argv[2]))" "$dir" "$PROJECT_ROOT")
      [ "$rel" = "." ] \
        && container_path="$CONTAINER_SRC/.venv" \
        || container_path="$CONTAINER_SRC/$rel/.venv"
      suffix=$(echo "$rel" | tr '/.-' '___' | sed 's/^\.$/root/')
      echo "volume: wt_${SLUG}_venv_${suffix}  ->  ${container_path}"
    done
```

Note: if the project uses a system Python inside the container (no `.venv`), skip the Python volume entirely — system site-packages are not a bind-mount concern.

**Other ecosystems** — apply the same `find`/`realpath` pattern with these signal files and vendor dirs:

| Ecosystem | Signal file     | Vendor dir                          |
| --------- | --------------- | ----------------------------------- |
| Ruby      | `Gemfile`       | `vendor/bundle`                     |
| Go        | `go.mod`        | `vendor` (only if present on disk)  |
| PHP       | `composer.json` | `vendor`                            |
| Rust      | `Cargo.toml`    | `target`                            |
| Java      | `pom.xml`       | `~/.m2` (shared; skip named volume) |
| .NET      | `*.csproj`      | `obj`, `bin`                        |

### 3. Write `docker-compose.override.yml`

Use the volume list produced in step 2 to write the override file. Every volume appears in both the service `volumes:` list and the top-level `volumes:` block.

**Always overwrite unconditionally — never skip this step even if the file already exists from a prior session.**

**Multi-service rule**: when the compose file defines more than one service, add **all** found volumes to **all** services. Do not try to infer which subdirectory belongs to which service — a volume attached to a service that doesn't use it is harmless; a missing volume breaks the build.

**Check `IS_SANDBOX`** before writing:

```bash
[ "$IS_SANDBOX" = "1" ] && SANDBOX=true || SANDBOX=false
```

If `SANDBOX=true`, add proxy environment variables and a CA bundle volume mount to every service. Include only the proxy variables the detected ecosystem's tooling reads:

| Tool                    | Proxy env var(s)                                                                |
| ----------------------- | ------------------------------------------------------------------------------- |
| npm / pnpm / bun / yarn | `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, `YARN_HTTPS_PROXY=${HTTPS_PROXY}` |
| pip / uv                | `HTTPS_PROXY`, `REQUESTS_CA_BUNDLE`                                             |
| cargo                   | `HTTPS_PROXY`, `SSL_CERT_FILE`                                                  |
| general (curl/wget)     | `HTTPS_PROXY`, `SSL_CERT_FILE`                                                  |

For the CA bundle bind-mount, use the path that matches the container's base image:

- Debian/Ubuntu: `/etc/ssl/certs/ca-certificates.crt`
- Alpine: `/etc/ssl/certs/ca-certificates.crt`
- RHEL/CentOS/Fedora: `/etc/pki/tls/certs/ca-bundle.crt`

If the base image is unknown, use the Debian/Ubuntu path and note the assumption.

Merge everything into one file — do **not** create a second override file.

Example for a Node.js project with `package.json` at root and `events/` subdirectory
(service `app`, `CONTAINER_SRC=/opt/app`, `SLUG=myproject`):

Non-sandbox:

```yaml
services:
  app:
    volumes:
      - wt_myproject_nm_root:/opt/app/node_modules
      - wt_myproject_nm_events:/opt/app/events/node_modules

volumes:
  wt_myproject_nm_root:
  wt_myproject_nm_events:
```

Sandbox (Node.js, Debian base image):

```yaml
services:
  app:
    environment:
      - HTTPS_PROXY
      - NODE_EXTRA_CA_CERTS
      - YARN_HTTPS_PROXY=${HTTPS_PROXY}
    volumes:
      - wt_myproject_nm_root:/opt/app/node_modules
      - wt_myproject_nm_events:/opt/app/events/node_modules
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro

volumes:
  wt_myproject_nm_root:
  wt_myproject_nm_events:
```

Multi-service sandbox example (services `serverless` and `playwright`, volumes at root, `events/`, and `tenants/`):

```yaml
services:
  serverless:
    environment:
      - HTTPS_PROXY
      - NODE_EXTRA_CA_CERTS
      - YARN_HTTPS_PROXY=${HTTPS_PROXY}
    volumes:
      - wt_myproject_nm_root:/opt/app/node_modules
      - wt_myproject_nm_events:/opt/app/events/node_modules
      - wt_myproject_nm_tenants:/opt/app/tenants/node_modules
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro

  playwright:
    environment:
      - HTTPS_PROXY
      - NODE_EXTRA_CA_CERTS
      - YARN_HTTPS_PROXY=${HTTPS_PROXY}
    volumes:
      - wt_myproject_nm_root:/opt/app/node_modules
      - wt_myproject_nm_events:/opt/app/events/node_modules
      - wt_myproject_nm_tenants:/opt/app/tenants/node_modules
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro

volumes:
  wt_myproject_nm_root:
  wt_myproject_nm_events:
  wt_myproject_nm_tenants:
```

### 4. Run install once

Named volumes start empty — always run install inside the container.

Check whether the Makefile has a public `install` or `deps` target whose recipe explicitly runs the package manager in every subdirectory that has a named volume (not just the root). If yes, use it:

```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$PROJECT_ROOT/docker-compose.override.yml" \
  run --rm <service> make install
```

Otherwise, run the package manager directly for each directory with a named volume. Pass all `cd && install` commands in a single `sh -c` to avoid re-starting the container per directory:

```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$PROJECT_ROOT/docker-compose.override.yml" \
  run --rm <service> sh -c "
    cd /opt/app && <install-command> &&
    cd /opt/app/events && <install-command>
  "
```

Pass both `-f` flags on every `docker compose` command.

### 5. All subsequent `docker compose` commands must pass both `-f` flags

Before every `docker compose` command (including test, lint, and type-check runs), verify the override file exists:

```bash
[ -f "$PROJECT_ROOT/docker-compose.override.yml" ] || {
  echo "ERROR: docker-compose.override.yml missing — re-run dep-install Step 3 before continuing"
  exit 1
}
```

If it is missing, go back to Step 3, regenerate it, and then retry the command. Never omit the `-f override` flag as a workaround.

## Install failures

If install fails because the container's entrypoint ignores the command, check the compose file for an `entrypoint:` key and override it:

```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$PROJECT_ROOT/docker-compose.override.yml" \
  run --rm --entrypoint sh <service> -c "<install-command>"
```

If install fails due to missing auth tokens, network errors, or Docker not running — stop immediately and report blocked with the verbatim error. Do not attempt workarounds.
