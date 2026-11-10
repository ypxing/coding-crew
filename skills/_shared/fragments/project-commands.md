**Run a project check by its key through `run-checks.sh`** — the suite, lint, typecheck, any key the dev commands
file has — never by retyping its command line: the dev commands file (a host's `CREW_COMMANDS_FILE` included)
decides what a key runs, and the command it gives may not be the one you would type. It runs every check and prints
each as `=== <key>: <command>`, then `<key>: pass` or `<key>: fail (exit N)`.

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run-checks.sh" --project-root "$(git rev-parse --show-toplevel)"
```

**Run every other project command through `run.sh`** — one test file, a look at an installed dependency, and any
ad-hoc command, a one-off `docker compose` one included. It runs the command where the dev commands file's
`install_mode` says: inside docker (with this checkout's compose override), where a docker-mode project's
dependencies are installed and the host has none, or on the host. Never hand-build a `docker compose` command. A
failure from such a command that looks like the environment (a missing service, socket or env variable) is
re-checked with `run-checks.sh` before any verdict.

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run.sh" --project-root "$(git rev-parse --show-toplevel)" -- "<command>"
```
