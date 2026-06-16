# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.0] - 2026-06-16

### ⚠️ BREAKING CHANGES

**Skill and agent names now use `crew-` namespace prefix**

All skills and agents have been renamed to prevent collisions when installed alongside other skill registries:

| Old Name                        | New Name                                |
| ------------------------------- | --------------------------------------- |
| `afk-run`                       | `crew-afk`                              |
| `plan-build`                    | `crew-plan`                             |
| `solve-issue`                   | `crew-solve-issue`                      |
| `address-code-review`           | `crew-address-code-review`              |
| `address-pr-comments`           | `crew-address-pr-comments`              |
| `tdd`                           | `crew-tdd`                              |
| `karpathy-guidelines`           | `crew-karpathy-guidelines`              |
| `dep-install`                   | `crew-dep-install`                      |
| `grill-me`                      | `crew-grill-me`                         |
| `grill-with-docs`               | `crew-grill-with-docs`                  |
| `to-issues`                     | `crew-to-issues`                        |
| `to-prd`                        | `crew-to-prd`                           |
| `improve-codebase-architecture` | `crew-improve-codebase-architecture`    |
| `caveman`                       | `crew-caveman`                          |
| `coder` (agent)                 | `crew-coder`                            |
| `code-reviewer` (agent)         | `crew-code-reviewer`                    |

**Migration:**

If you have existing skills installed, you must uninstall and reinstall:

```bash
# Uninstall old version
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash

# Install new version
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

All skill invocations now use the `crew-` prefix:
- `/afk-run` → `/crew-afk`
- `/plan-build` → `/crew-plan`
- `/solve-issue` → `/crew-solve-issue`
- etc.

Install destination directories also use the prefix: `.claude/skills/crew-afk/`, `.claude/skills/crew-tdd/`, etc.
Agent files also use the prefix: `.claude/agents/crew-coder.md`, `.claude/agents/crew-code-reviewer.md`.

### Added

- **Lockfile-based version pinning**: `install.sh --from-lockfile crew.lock` installs specific versions from a lockfile, enabling reproducible team distributions
- **Lockfile update command**: `install.sh --update` with an existing `crew.lock` checks for newer releases, upgrades, and rewrites the lockfile with updated versions
- **Diff-before-overwrite**: When installing over existing files, `install.sh` now prints a unified diff to show exactly what changed before overwriting
- **CI coverage**: Automated tests now run on macOS, Linux, and WSL2 environments

### Changed

- `registry.json`: All skill and agent keys, install paths, and dependency references updated to use `crew-` prefix
- `install.sh`: Identifier validation updated for `crew-` style names
- `install.sh`: Enhanced dependency checking for `curl` and `tar` (required for lockfile fetching)
- `README.md`: All examples updated to use new skill and agent names
- `CLAUDE.md`: Documentation updated to reflect new naming convention
