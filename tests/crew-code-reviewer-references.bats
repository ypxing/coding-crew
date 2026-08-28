#!/usr/bin/env bats

# P5 — the reviewer's framework checklists are conditional references, selected mechanically.
#
# Before this, protocol.md carried every checklist inline: React/Next patterns in a Go repo, a
# Node/backend block in a static site, and a six-row dependency-audit table the model executed by
# hand. The audit's instruction was explicit — do not blind-cut the checklist, make the framework
# blocks conditional. So nothing was deleted: the blocks moved to
# .coding-crew/code-review/references/, and review-context.sh decides which apply from signal
# files. These tests prove both halves: the relocation is lossless, and the selection is correct
# per stack. The negative greps lock the trim in (the P0 technique) so an inline checklist cannot
# creep back.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export AGENT_DIR="$SCRIPT_DIR/agents/crew-code-reviewer"
  export PROTOCOL="$AGENT_DIR/protocol.md"
  export ASSETS="$AGENT_DIR/assets"
  export CONTEXT_SH="$ASSETS/scripts/review-context.sh"
  export AUDIT_SH="$ASSETS/scripts/dependency-audit.sh"
  export TEMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# Builds a fixture repo at $TEMP_DIR/<name> containing the given files (name:content pairs are
# written literally). Not a git repo — the detector must work on a bare directory too.
fixture() {
  local name="$1"; shift
  mkdir -p "$TEMP_DIR/$name"
  while [[ $# -gt 0 ]]; do
    printf '%s' "${2:-}" > "$TEMP_DIR/$name/$1"
    shift 2
  done
  printf '%s' "$TEMP_DIR/$name"
}

refs_for() {
  bash "$CONTEXT_SH" --root "$1" | awk '/^REFERENCE: /{print $2}' | xargs -n1 basename 2>/dev/null
}

stack_for() {
  bash "$CONTEXT_SH" --root "$1" | awk '/^STACK: /{$1=""; print}' | sed 's/^ //'
}

# ─── Assets exist and are wired into the registry ─────────────────────────────

@test "every reference file the protocol relies on exists" {
  for f in quality.md web-security.md react.md backend.md; do
    [ -f "$ASSETS/references/$f" ]
  done
}

@test "both review scripts exist and are executable as bash" {
  [ -f "$CONTEXT_SH" ]
  [ -f "$AUDIT_SH" ]
  bash -n "$CONTEXT_SH"
  bash -n "$AUDIT_SH"
}

@test "registry declares the reviewer's assets install path" {
  run jq -r '.agents["crew-code-reviewer"].install.assets.dest' "$SCRIPT_DIR/registry.json"
  [ "$output" = ".coding-crew/code-review" ]
}

# ─── Relocation is lossless ──────────────────────────────────────────────────

@test "no checklist item was deleted — every pre-P5 class survives in protocol or a reference" {
  # Snapshot of the checklist vocabulary the protocol carried inline before P5. Each entry must
  # still be findable somewhere the reviewer reads, otherwise the trim deleted a control.
  local union="$TEMP_DIR/union.txt"
  cat "$PROTOCOL" "$ASSETS/references/"*.md > "$union"
  local item
  for item in \
    "Hardcoded credentials" "Injection" "XSS" "Path traversal" "CSRF" \
    "Authentication bypass" "Broken access control" "SSRF" "Insecure deserialization" \
    "XXE" "Sensitive data exposure" "Security misconfiguration" "Insecure dependencies" \
    "Large functions" "Large files" "Deep nesting" "Missing error handling" \
    "Mutation patterns" "console.log" "Missing tests" "Dead code" \
    "Missing dependency arrays" "State updates in render" "Missing keys in lists" \
    "Prop drilling" "Client/server boundary" "Missing loading/error states" "Stale closures" \
    "Unvalidated input" "Missing rate limiting" "Unbounded queries" "Missing timeouts" \
    "Error message leakage" "Missing CORS configuration" \
    "Inefficient algorithms" "Large bundle sizes" "Missing caching" "Synchronous I/O" \
    "TODO/FIXME without tickets" "Missing JSDoc for public APIs" "Poor naming" \
    "Inconsistent formatting"; do
    grep -qF "$item" "$union" || { echo "lost checklist item: $item"; return 1; }
  done
}

@test "the load-bearing discipline sections stay inline in the protocol" {
  grep -q 'Pre-Report Gate' "$PROTOCOL"
  grep -q 'Common False Positives' "$PROTOCOL"
  grep -q 'Zero Findings Is Valid' "$PROTOCOL"
  grep -qi 'every severity' "$PROTOCOL"
  grep -q '## Branch:' "$PROTOCOL"
  grep -q '\[CRITICAL\]' "$PROTOCOL"
}

@test "framework-specific checklists are no longer inline in the protocol" {
  ! grep -q 'useEffect' "$PROTOCOL"
  ! grep -q 'Prop drilling' "$PROTOCOL"
  ! grep -q 'Missing rate limiting' "$PROTOCOL"
  ! grep -qi 'bundle size' "$PROTOCOL"
}

@test "the dependency-audit command table is no longer inline in the protocol" {
  ! grep -q 'audit-level=high' "$PROTOCOL"
  ! grep -q 'govulncheck' "$PROTOCOL"
  grep -q 'dependency-audit.sh' "$PROTOCOL"
}

@test "protocol instructs reading every REFERENCE line and names both scripts" {
  grep -q 'review-context.sh' "$PROTOCOL"
  grep -q 'REFERENCE:' "$PROTOCOL"
  grep -qiE 'read \*\*every\*\* file named by a `REFERENCE:`|read every file named by a' "$PROTOCOL"
}

@test "protocol keeps a fallback for an install without the scripts" {
  grep -qiE 'if either script is missing|older install' "$PROTOCOL"
}

@test "protocol body stays under the 1660-word budget" {
  # Raised from 1,500 by the two *machine* contracts the protocol now owns, both of which
  # replace an inference the caller used to make: the execution-evidence rule (a read-only
  # reviewer cannot run `npm test`, so a criterion ending "…and the tests pass" was
  # unanswerable and stalled every such branch) and the `FINDING: <SEV> | <file:line> |
  # <criterion>` line (promotion into a fix issue now parses one line instead of re-reading
  # prose). Duplication was cut first — the criteria rule was stated twice, the session-summary
  # rule three ways — so this is what the contracts cost after that, not on top of it.
  #
  # 1,560 → 1,660: an "Incorrect logic" HIGH class for AI-generated bugs with no prior
  # behaviour to regress from, a negative-criteria evidence rule (an absence criterion had no
  # citable line and no guidance, so it either got rubber-stamped or stuck at `unmet` forever),
  # and a lockfile/generated-file exclusion before the diff-size top-10 cut (those files were
  # crowding the review budget out of the files that actually carry logic).
  local words
  words=$(wc -w < "$PROTOCOL")
  [ "$words" -lt 1660 ] || { echo "protocol.md is $words words"; return 1; }
}

@test "no single reference is larger than the protocol that conditions it" {
  local protocol_words ref words
  protocol_words=$(wc -w < "$PROTOCOL")
  for ref in "$ASSETS/references/"*.md; do
    words=$(wc -w < "$ref")
    [ "$words" -lt "$protocol_words" ] || { echo "$ref is $words words"; return 1; }
  done
}

# ─── Selection is correct per stack ──────────────────────────────────────────

@test "a generic repo loads quality only — no React or backend noise" {
  local root; root=$(fixture generic a.sh 'echo hi')
  run refs_for "$root"
  [ "$output" = "quality.md" ]
  [ "$(stack_for "$root")" = "generic" ]
}

@test "a React/Next repo loads react and web-security" {
  local root; root=$(fixture reactrepo package.json '{"dependencies":{"next":"14","react":"18"}}')
  run refs_for "$root"
  [[ "$output" == *"react.md"* ]]
  [[ "$output" == *"web-security.md"* ]]
  [[ "$output" != *"backend.md"* ]]
}

@test "a .tsx file alone is enough to load the react reference" {
  local root; root=$(fixture tsxrepo App.tsx 'export const A = () => null;')
  run refs_for "$root"
  [[ "$output" == *"react.md"* ]]
}

@test "a Go service repo loads backend and web-security, not react" {
  local root; root=$(fixture gorepo go.mod 'module x
require github.com/gin-gonic/gin v1.9.0')
  run refs_for "$root"
  [[ "$output" == *"backend.md"* ]]
  [[ "$output" != *"react.md"* ]]
}

@test "a Python service repo loads backend" {
  local root; root=$(fixture pyrepo requirements.txt 'flask==3.0.0')
  run refs_for "$root"
  [[ "$output" == *"backend.md"* ]]
}

@test "an Express repo loads backend" {
  local root; root=$(fixture noderepo package.json '{"dependencies":{"express":"4.19.0"}}')
  run refs_for "$root"
  [[ "$output" == *"backend.md"* ]]
  [[ "$output" != *"react.md"* ]]
}

@test "a static HTML repo loads web-security without backend or react" {
  local root; root=$(fixture staticsite index.html '<html></html>')
  run refs_for "$root"
  [[ "$output" == *"web-security.md"* ]]
  [[ "$output" != *"backend.md"* ]]
  [[ "$output" != *"react.md"* ]]
}

@test "quality.md is loaded for every stack" {
  local root
  for pair in "g1:a.sh" "g2:index.html" "g3:App.tsx"; do
    root=$(fixture "${pair%%:*}" "${pair##*:}" 'x')
    run refs_for "$root"
    [[ "$output" == *"quality.md"* ]]
  done
}

@test "review-context.sh exits 0 and reports none when the references are missing" {
  mkdir -p "$TEMP_DIR/lonely/scripts"
  cp "$CONTEXT_SH" "$TEMP_DIR/lonely/scripts/"
  run bash "$TEMP_DIR/lonely/scripts/review-context.sh" --root "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REFERENCE: none"* ]]
}

@test "review-context.sh defaults to the current repo root when --root is omitted" {
  cd "$SCRIPT_DIR"
  run bash "$CONTEXT_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STACK: "* ]]
}

# ─── Dependency audit ────────────────────────────────────────────────────────

@test "dependency-audit.sh reports NO MANIFEST FOUND and exits 0 on a repo with none" {
  local root; root=$(fixture nomanifest a.sh 'echo hi')
  run bash "$AUDIT_SH" --root "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO MANIFEST FOUND"* ]]
}

@test "dependency-audit.sh reports NOT RUN rather than failing when the tool is absent" {
  local root; root=$(fixture pyaudit requirements.txt 'flask==3.0.0')
  # Empty PATH beyond the shell builtins: no audit tool can be found.
  run env PATH="/nonexistent" /bin/bash "$AUDIT_SH" --root "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT RUN:"* ]]
  [[ "$output" == *"### pip-audit"* ]]
}

@test "dependency-audit.sh emits one block per manifest found" {
  local root
  root=$(fixture multi package-lock.json '{}' go.sum 'x' Gemfile.lock 'y')
  run env PATH="/nonexistent" /bin/bash "$AUDIT_SH" --root "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"### npm audit"* ]]
  [[ "$output" == *"### govulncheck"* ]]
  [[ "$output" == *"### bundle audit"* ]]
}

# ─── Install / uninstall ─────────────────────────────────────────────────────

@test "installing the reviewer ships references and executable scripts" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer >/dev/null
  [ -f "$TEMP_DIR/.coding-crew/code-review/references/quality.md" ]
  [ -f "$TEMP_DIR/.coding-crew/code-review/references/react.md" ]
  [ -x "$TEMP_DIR/.coding-crew/code-review/scripts/review-context.sh" ]
  [ -x "$TEMP_DIR/.coding-crew/code-review/scripts/dependency-audit.sh" ]
}

@test "assets are always overwritten — a stale reference cannot survive a re-install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer >/dev/null
  echo "STALE" > "$TEMP_DIR/.coding-crew/code-review/references/quality.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer >/dev/null
  ! grep -q 'STALE' "$TEMP_DIR/.coding-crew/code-review/references/quality.md"
  grep -q 'Code Quality' "$TEMP_DIR/.coding-crew/code-review/references/quality.md"
}

@test "the installed scripts resolve the installed references" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer >/dev/null
  mkdir -p "$TEMP_DIR/app"
  printf '{"dependencies":{"react":"18"}}' > "$TEMP_DIR/app/package.json"
  run bash "$TEMP_DIR/.coding-crew/code-review/scripts/review-context.sh" --root "$TEMP_DIR/app"
  [ "$status" -eq 0 ]
  [[ "$output" == *".coding-crew/code-review/references/react.md"* ]]
}

@test "uninstalling the reviewer removes its assets" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer >/dev/null
  [ -d "$TEMP_DIR/.coding-crew/code-review" ]
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --agent crew-code-reviewer >/dev/null
  [ ! -d "$TEMP_DIR/.coding-crew/code-review" ]
}
