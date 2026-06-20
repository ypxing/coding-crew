# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.5.0] - 2026-06-20

### ⚠️ BREAKING CHANGES

**`crew-plan` renamed to `crew-grill`**

The skill has been renamed to better reflect its role as the grill/interview phase of the design pipeline. The new `crew-brainstorm` skill now serves as the full end-to-end design orchestrator.

| Old Name       | New Name      |
| -------------- | ------------- |
| `crew-plan`    | `crew-grill`  |

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

### Added

- **`crew-brainstorm` skill**: Full design pipeline — captures slug, explores context, conducts Q&A, proposes approaches, builds `design.md` section by section, then auto-transitions to `to-prd` and `to-issues`.

### Changed

- **`to-issues`**: Reads `design.md` from the feature workspace when present, feeding it as context for issue generation. Issue template gains an optional `## Interfaces` section. Skill version bumped to `1.2.0`.

---

## [1.4.0] - 2026-06-20

### ⚠️ BREAKING CHANGES

**`address-code-review` renamed to `crew-address-findings`**

The skill has been renamed to clarify its purpose (acts on the `crew-code-reviewer` report, not inline PR comments) and avoid confusion with `address-pr-comments`.

| Old Name                | New Name                  |
| ----------------------- | ------------------------- |
| `address-code-review`   | `crew-address-findings`   |

**`grill-me` and `grill-with-docs` removed**

Both skills have been removed and replaced by the new `domain-modeling` skill and an inlined grill loop inside `crew-plan`.

| Removed                 | Replacement                         |
| ----------------------- | ----------------------------------- |
| `/grill-me`             | `/crew-plan`                        |
| `/grill-with-docs`      | `/crew-plan with docs`              |

**Tracker install simplified to project-level only**

The `--user` flag and user-level tracker fallback path have been removed from `install.sh` and all skills. All tracker operations now target the project-level path only.

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

### Added

- **`domain-modeling` skill**: Extracted from `grill-with-docs`. Handles CONTEXT.md glossary and ADR updating behavior. Reference format files live under `skills/domain-modeling/references/`.

### Changed

- **`crew-plan`**: Inlines the grill interview loop directly; lite mode runs the grill only; `with docs` mode invokes the new `domain-modeling` skill.
- **`improve-codebase-architecture`**: Updated dep reference from `grill-with-docs` to `domain-modeling`.
- **`crew-afk`, `solve-issue`, `crew-address-findings`, `to-issues`, `to-prd`, `configure-tracker`**: Simplified tracker lookup to project-level only (no user-level fallback).

### Removed

- **`grill-me` skill**: Use `/crew-plan` instead.
- **`grill-with-docs` skill**: Use `/crew-plan with docs` instead.

---

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
