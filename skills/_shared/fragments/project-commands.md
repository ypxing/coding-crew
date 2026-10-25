**Run every project command through `run.sh`** — test runs, type checks, linting, a look at an installed
dependency, and any ad-hoc command, a one-off `docker compose` one included. It runs the command where the dev
commands file's `install_mode` says: inside docker (with this checkout's compose override), where a docker-mode
project's dependencies are installed and the host has none, or on the host. Never hand-build a `docker compose`
command.

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run.sh" --project-root "$(git rev-parse --show-toplevel)" -- "<command>"
```
