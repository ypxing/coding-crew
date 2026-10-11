# Shared bats helper: installs a file makes once in setup_file, under $BATS_FILE_TMPDIR, for tests
# that only read what an install leaves behind. The installs run in the background so a file's
# installs overlap; bg_wait fails setup_file, printing each failed log.

SHARED_INSTALL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_BG_JOBS=()

# bg_start <name> <command>... — run <command> in the background, its output to <name>.log.
bg_start() {
  local name="$1"; shift
  "$@" > "$BATS_FILE_TMPDIR/$name.log" 2>&1 &
  _BG_JOBS+=("$!:$name")
}

bg_wait() {
  local job failed=0
  for job in "${_BG_JOBS[@]}"; do
    wait "${job%%:*}" && continue
    echo "${job#*:} failed:" >&2
    cat "$BATS_FILE_TMPDIR/${job#*:}.log" >&2
    failed=1
  done
  _BG_JOBS=()
  return "$failed"
}

_install_into() {
  local target="$1"; shift
  mkdir -p "$target"
  cd "$SHARED_INSTALL_SRC" && TARGET_REPO="$target" ./install.sh "$@"
}

# shared_install <name> <install.sh arg>... — start an install into $(shared_installed <name>).
shared_install() {
  local name="$1"; shift
  bg_start "$name" _install_into "$(shared_installed "$name")" "$@"
}

shared_installed() { printf '%s\n' "$BATS_FILE_TMPDIR/installs/$1"; }
