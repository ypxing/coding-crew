#!/usr/bin/env bats

# The per-platform agent shims are hand-written copies of one role each. What must agree across
# them — name, description, and a read-only role never getting write access — is checked here on
# the installed output, so a shim edited on one platform only fails instead of drifting.

setup_file() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export INSTALL_DIR="$(mktemp -d)"
  (cd "$SCRIPT_DIR" && TARGET_REPO="$INSTALL_DIR" ./install.sh all --skill crew-afk >/dev/null)
}

teardown_file() {
  rm -rf "$INSTALL_DIR"
}

# _shim <platform> <agent> — the installed file for one platform
_shim() {
  case "$1" in
    claude) echo "$INSTALL_DIR/.claude/agents/$2.md" ;;
    copilot) echo "$INSTALL_DIR/.github/agents/$2.agent.md" ;;
    pi) echo "$INSTALL_DIR/.pi/agents/$2.md" ;;
    codex) echo "$INSTALL_DIR/.codex/agents/$2.toml" ;;
  esac
}

# _field <platform> <agent> <key> — a frontmatter/TOML value, folded onto one line
_field() {
  local f
  f=$(_shim "$1" "$2")
  if [[ "$1" == codex ]]; then
    sed -n "s/^$3 = \"\(.*\)\"$/\1/p" "$f" | head -1
  else
    awk -v key="$3" '
      /^---$/ { n++; next }
      n != 1 { next }
      $0 ~ "^" key ":" { grab = 1; v = $0; sub("^" key ":[[:space:]]*>?[[:space:]]*", "", v); out = v; next }
      grab && /^[[:space:]]/ { v = $0; sub(/^[[:space:]]+/, "", v); out = out (out == "" ? "" : " ") v; next }
      { grab = 0 }
      END { print out }
    ' "$f"
  fi
}

# The coder's description names its own dispatch command ("a separate `claude -p` process"), the
# one wording that is meant to differ per platform.
_normalised_description() {
  _field "$1" "$2" description | sed -E 's/a separate [^,]* process in/a separate <cli> process in/'
}

@test "each crew agent has the same name on every platform" {
  for a in crew-coder crew-reviewer crew-triage; do
    for p in claude copilot pi codex; do
      [ "$(_field "$p" "$a" name)" = "$a" ] || { echo "$p/$a: name is '$(_field "$p" "$a" name)'"; return 1; }
    done
  done
}

@test "each crew agent has the same description on every platform" {
  for a in crew-coder crew-reviewer crew-triage; do
    local want
    want=$(_normalised_description claude "$a")
    [ -n "$want" ]
    for p in copilot pi codex; do
      [ "$(_normalised_description "$p" "$a")" = "$want" ] || {
        echo "$p/$a description differs from claude's:"
        echo "  claude: $want"
        echo "  $p: $(_normalised_description "$p" "$a")"
        return 1
      }
    done
  done
}

@test "read-only agents get no write tools on any platform" {
  # `if`, not a bare `! cmd`: bats only fails on a negated command when it is the last line.
  for a in crew-reviewer crew-triage; do
    if _field claude "$a" tools | grep -qE '"(Edit|Write|NotebookEdit)"'; then echo "claude/$a can write"; return 1; fi
    if _field copilot "$a" tools | grep -qE '"(edit|create)"'; then echo "copilot/$a can write"; return 1; fi
    if _field pi "$a" tools | grep -qwE 'edit|write'; then echo "pi/$a can write"; return 1; fi
    [ "$(_field codex "$a" sandbox_mode)" = "read-only" ]
  done
}

@test "read-only agents state the read-only rule in their shared protocol, not per shim" {
  for a in crew-reviewer crew-triage; do
    for p in claude copilot pi codex; do
      grep -q 'Never edit, write, commit, or change branches' "$(_shim "$p" "$a")"
    done
  done
}

@test "crew-coder is the one agent codex lets write" {
  [ "$(_field codex crew-coder sandbox_mode)" = "workspace-write" ]
}
