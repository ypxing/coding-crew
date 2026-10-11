#!/usr/bin/env bats

# P5 — the reviewer's framework checklists are conditional references, selected mechanically.
#
# Before this, protocol.md carried every checklist inline: React/Next patterns in a Go repo, a
# Node/backend block in a static site, and a six-row dependency-audit table the model executed by
# hand. The audit's instruction was explicit — do not blind-cut the checklist, make the framework
# blocks conditional. So nothing was deleted: the blocks moved to
# .coding-crew/crew-afk/roles/reviewer/references/, and review-context.sh decides which apply from signal
# files. These tests check the selection per stack, and that the references ship with crew-afk.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export AGENT_DIR="$SCRIPT_DIR/orchestrator/roles"
  export ASSETS="$AGENT_DIR/reviewer"
  export CONTEXT_SH="$ASSETS/scripts/review-context.sh"
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

@test "the review-context script exists and parses as bash" {
  [ -f "$CONTEXT_SH" ]
  bash -n "$CONTEXT_SH"
}

@test "the reviewer's assets ship inside crew-afk's orchestrator asset" {
  run jq -r '.skills["crew-afk"].assets | "\(.source) \(.dest)"' "$SCRIPT_DIR/registry.json"
  [ "$output" = "orchestrator .coding-crew/crew-afk" ]
  [ -d "$SCRIPT_DIR/orchestrator/roles/reviewer/references" ]
}

# ─── Selection is correct per stack ──────────────────────────────────────────

@test "a generic repo loads quality only - no React or backend noise" {
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

# ─── Install / uninstall ─────────────────────────────────────────────────────

@test "installing crew-afk ships the reviewer's references, feature part and executable script" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  [ -f "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer/references/quality.md" ]
  [ -f "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer/references/react.md" ]
  [ -x "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer/scripts/review-context.sh" ]
  [ -f "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer/feature.md" ]
}

@test "assets are always overwritten - a stale reference cannot survive a re-install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  echo "STALE" > "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer/references/quality.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  cmp "$ASSETS/references/quality.md" "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer/references/quality.md"
}

@test "the installed scripts resolve the installed references" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  mkdir -p "$TEMP_DIR/app"
  printf '{"dependencies":{"react":"18"}}' > "$TEMP_DIR/app/package.json"
  run bash "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer/scripts/review-context.sh" --root "$TEMP_DIR/app"
  [ "$status" -eq 0 ]
  [[ "$output" == *".coding-crew/crew-afk/roles/reviewer/references/react.md"* ]]
}

@test "uninstalling crew-afk removes the reviewer's assets" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  [ -d "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer" ]
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill crew-afk >/dev/null
  [ ! -d "$TEMP_DIR/.coding-crew/crew-afk/roles/reviewer" ]
}
