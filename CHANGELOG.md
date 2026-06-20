# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.3.0] - 2026-06-20

### Added

- **`configure-tracker` skill**: Interactive menu to select and install an issue tracker template. Presents available templates from `docs/templates/trackers/`, then writes the chosen template to `docs/agents/issue-tracker.md` in the target repo.

---

## [1.2.0] - 2026-06-17

### ⚠️ BREAKING CHANGES

**`crew-` prefix removed from skills (except `crew-afk` and `crew-plan`)**

Skills have been renamed to drop the `crew-` prefix. `crew-afk` and `crew-plan` are unchanged.

| Old Name                          | New Name                          |
| --------------------------------- | --------------------------------- |
| `crew-karpathy-guidelines`        | `karpathy-guidelines`             |
| `crew-tdd`                        | `tdd`                             |
| `crew-dep-install`                | `dep-install`                     |
| `crew-solve-issue`                | `solve-issue`                     |
| `crew-address-code-review`        | `address-code-review`             |
| `crew-address-pr-comments`        | `address-pr-comments`             |
| `crew-improve-codebase-architecture` | `improve-codebase-architecture` |
| `crew-grill-me`                   | `grill-me`                        |
| `crew-grill-with-docs`            | `grill-with-docs`                 |
| `crew-to-issues`                  | `to-issues`                       |
| `crew-to-prd`                     | `to-prd`                          |
| `crew-caveman`                    | `caveman`                         |

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Install paths change accordingly: `.claude/skills/tdd/`, `.claude/skills/solve-issue/`, etc.

---

## [1.1.0] - 2026-06-16

### Added

- **`--version` flag for bootstrap**: `bash -s -- --version v1.0.0` pins the install to a specific GitHub release tag instead of always pulling `main`
- **Automatic doc updates in `crew-solve-issue`**: New Step 4.5 prompts the agent to update `README.md`, `CLAUDE.md`, or `docs/` when a change affects user-facing behavior, public API, or architecture. Purely internal changes skip the step.

---

## [1.0.0] - 2026-06-16

### ⚠️ BREAKING CHANGES

**Skill and agent names now use `crew-` namespace prefix**

All skills and agents have been renamed to prevent collisions when installed alongside other skill registries:

| Old Name                        | New Name                                |
| ------------------------------- | --------------------------------------- |
| `crew:afk`                      | `crew-afk`                              |
| `crew:plan`                     | `crew-plan`                             |
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
- `/crew:afk` → `/crew-afk`
- `/crew:plan` → `/crew-plan`
- `/crew:solve-issue` → `/crew-solve-issue`
- etc.

Install destination directories also use the prefix: `.claude/skills/crew-afk/`, `.claude/skills/crew-tdd/`, etc.
Agent files also use the prefix: `.claude/agents/crew-coder.md`, `.claude/agents/crew-code-reviewer.md`.

### Added

- **Lockfile-based version pinning**: `install.sh --from-lockfile crew.lock` installs specific versions from a lockfile, enabling reproducible team distributions
- **Lockfile update command**: `install.sh --update` with an existing `crew.lock` checks for newer releases, upgrades, and rewrites the lockfile with updated versions
- **Diff-before-overwrite**: When installing over existing files, `install.sh` now prints a unified diff to show exactly what changed before overwriting
- **CI coverage**: Automated tests now run on macOS, Linux, and Windows (Git Bash)

### Changed

- `registry.json`: All skill and agent keys, install paths, and dependency references updated to use `crew-` prefix
- `install.sh`: Identifier validation updated for `crew-` style names
- `README.md`: All examples updated to use new skill and agent names
- `CLAUDE.md`: Documentation updated to reflect new naming convention
