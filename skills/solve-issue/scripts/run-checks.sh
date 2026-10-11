#!/usr/bin/env bash
# run-checks.sh — run every check .coding-crew/dev-commands.json names, each through
# dep-install's run.sh, and report each one.
#
# Usage:
#   bash scripts/run-checks.sh --project-root <path> --main-root <path> --dep-scripts <dir> [--targeted]
#
# Order: typecheck, lint, test, then every other key with a command, as crew-afk's verify gate runs them.
# --targeted (only under CREW_DEFER_FULL_CHECKS=1) runs the test command on just the test files changed
# since the merge-base with CREW_BASE_REF (default: origin/HEAD, origin/main, main, master).
# Prints per check `<key>: pass`, `<key>: fail (exit N)` (then its output tail and log path), `<key>: NOT
# RUN: no command found` (the cache's null), `<key>: modified files: <list>` (the check rewrote files;
# then a fail), `(targeted)` variants, or `<key>: deferred …` (the verify gate runs it); last, CHECKS:
# pass (exit 0) | CHECKS: fail (exit 1) | DISCOVER (exit 3: no usable cache).

set -uo pipefail

PROJECT_ROOT=""
MAIN_ROOT=""
DEP_SCRIPTS=""
TARGETED=0
TAIL_LINES="${CREW_CHECK_TAIL_LINES:-80}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--main-root|--dep-scripts)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      case "$1" in
        --project-root) PROJECT_ROOT="$2" ;;
        --main-root) MAIN_ROOT="$2" ;;
        --dep-scripts) DEP_SCRIPTS="$2" ;;
      esac
      shift 2
      ;;
    --targeted) TARGETED=1; shift ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROJECT_ROOT" ] || [ ! -d "$PROJECT_ROOT" ]; then
  echo "Error: --project-root <existing dir> is required" >&2
  exit 2
fi
RUN_SCRIPT="$DEP_SCRIPTS/run.sh"
if [ -z "$DEP_SCRIPTS" ] || [ ! -f "$RUN_SCRIPT" ]; then
  echo "Error: --dep-scripts must name dep-install's scripts directory (no run.sh at '$DEP_SCRIPTS')" >&2
  exit 2
fi

_main_root_of() {
  local dir="$1" common
  common=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*|[A-Za-z]:*) : ;;
    *) common="$dir/$common" ;;
  esac
  common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")"
  dirname "$common"
}
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$(_main_root_of "$PROJECT_ROOT" 2>/dev/null || true)"
CACHE="${MAIN_ROOT:+$MAIN_ROOT/.coding-crew/dev-commands.json}"

if [ -z "$CACHE" ] || [ ! -f "$CACHE" ] || ! grep -q '"test"' "$CACHE" 2>/dev/null; then
  echo "DISCOVER"
  exit 3
fi

# Keys of dev-commands.json that are not checks — kept in step with verify-worktree.sh's own list.
NOT_CHECKS=" test lint typecheck install install_mode env credential_target docker_service "

# _cached <key> — its command; empty for `null` or an absent key. Parsed as verify-worktree.sh does.
_cached() {
  local raw
  raw=$(grep -o "\"$1\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|null\)" "$CACHE" 2>/dev/null | head -1 | sed -E "s/\"$1\"[[:space:]]*:[[:space:]]*//")
  case "$raw" in
    \"*\") raw="${raw#\"}"; printf '%s' "${raw%\"}" ;;
  esac
}

KEYS=(typecheck lint test)
while IFS= read -r key; do
  [[ "$NOT_CHECKS" == *" $key "* ]] || KEYS+=("$key")
done < <(grep -oE '"[a-z][a-z0-9_]*"[[:space:]]*:[[:space:]]*("|null)' "$CACHE" 2>/dev/null \
  | sed -E 's/^"([a-z0-9_]+)".*/\1/' | awk '!seen[$0]++')

# A check must leave the tree as it found it (the verify gate's rule); prior dirt is in the before snapshot.
_tree_state() {
  git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | LC_ALL=C sort
}
_changed_files() {
  LC_ALL=C comm -3 <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
    | sed -E 's/^\t//; s/^...//' \
    | awk 'NF && !seen[$0]++ { printf "%s%s", (n++ ? ", " : ""), $0 }'
}

# A test file by its own name: a file under tests/ may be a helper or fixture.
TEST_FILE_RE='(\.bats$|\.(test|spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$|_test\.[A-Za-z0-9]+$|_spec\.rb$|Test\.php$|(^|/)__tests__/.*\.[cm]?[jt]sx?$|(^|/)test/[^/]*\.[cm]?[jt]s$)'
# Never a suite file, whatever its name: data and helpers inside a test tree, snapshots.
NOT_TEST_RE='((^|/)(tests?|spec|__tests__)/(.*/)?(fixtures?|helpers?|__fixtures__|testdata)/|(^|/)(__snapshots__|testdata)/)'
# Runners that take no test file arguments: a targeted run through them would not run the changed tests.
NO_FILE_ARGS_RE='^(make|gmake|go|cargo|gradle|gradlew|\./gradlew|mvn|mvnw|\./mvnw|dotnet|rake|ctest|tox|nox)$'

_changed_tests() {
  local ref base="" cand
  for cand in "${CREW_BASE_REF:-}" origin/HEAD origin/main main master; do
    [ -n "$cand" ] || continue
    if git -C "$PROJECT_ROOT" rev-parse --verify -q "$cand^{commit}" >/dev/null 2>&1; then
      base="$(git -C "$PROJECT_ROOT" merge-base HEAD "$cand" 2>/dev/null)" && [ -n "$base" ] && break
      base=""
    fi
  done
  {
    [ -z "$base" ] || git -C "$PROJECT_ROOT" diff --name-only --diff-filter=d "$base" HEAD 2>/dev/null
    git -C "$PROJECT_ROOT" diff --name-only --diff-filter=d HEAD 2>/dev/null
    git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null
  } | awk 'NF && !seen[$0]++' | grep -E "$TEST_FILE_RE" | grep -vE "$NOT_TEST_RE" | while IFS= read -r f; do
    [ -f "$PROJECT_ROOT/$f" ] && printf '%s\n' "$f"
  done
}

# _takes_test_files <cached test command> — false when the first word of any `&&`/`;`/`|` segment,
# past env assignments and wrappers (`env`, `bundle exec`, `poetry run`, …), is in NO_FILE_ARGS_RE.
_takes_test_files() {
  local w prev="" at_prog=1 wrapper=""
  set -f
  for w in ${1//;/ ; }; do
    if [ -n "$wrapper" ]; then wrapper=""; prev="$w"; continue; fi # `exec` of `bundle exec`, …
    case "$w" in "&&"|";"|"||"|"|") at_prog=1; prev="$w"; continue ;; esac
    if [ "$at_prog" = 1 ]; then
      case "$w" in
        [A-Za-z_]*=*|env|time|nice|command|exec) prev="$w"; continue ;;
        bundle|poetry|uv|pipenv|pdm|hatch|rye) wrapper=1; prev="$w"; continue ;;
      esac
      at_prog=0
      if [ "$w" != cd ] && grep -qE "$NO_FILE_ARGS_RE" <<<"$w"; then set +f; return 1; fi
    fi
    prev="$w"
  done
  set +f
  return 0
}

_norm_path() {
  local p="$1" seg out=() n noglob=0 IFS=/
  case "$-" in *f*) noglob=1 ;; esac
  set -f # a glob's segments are kept as written
  for seg in $p; do
    n=${#out[@]}
    case "$seg" in
      ''|.) ;;
      ..) if [ "$n" -gt 0 ] && [ "${out[$((n - 1))]}" != .. ]; then unset "out[$((n - 1))]"; else out+=(..); fi ;;
      *) out+=("$seg") ;;
    esac
  done
  [ "$noglob" = 1 ] || set +f
  case "$p" in /*) printf '/%s' "${out[*]}" ;; *) printf '%s' "${out[*]}" ;; esac
}

# _suite_selects <suite word, absolute> <file, absolute> — whether the suite argument selects the file:
# a glob as the shell expands it (`**` spans directories, `**/` may be none), a directory, or the file.
_suite_selects() {
  local s="$1" f="$2" sd fd
  case "$s" in
    *[\*\?\[]*)
      if [[ "$s" == *'**'* ]]; then
        # shellcheck disable=SC2053 # $s is the pattern
        [[ "$f" == $s ]] || [[ "$f" == ${s//\*\*\//} ]]
      else
        sd="${s//[^\/]/}"; fd="${f//[^\/]/}"
        # shellcheck disable=SC2053
        [ "${#sd}" = "${#fd}" ] && [[ "$f" == $s ]]
      fi ;;
    *) [ "$f" = "$s" ] || [[ "$f" == "${s%/}"/* ]] ;;
  esac
}

# _targeted_command <cached test command> <files…> — the command with its suite arguments (a glob, or
# an existing directory or test file outside program position) replaced by the files they select (all,
# with none); after a `cd`, files are passed relative to its target. None left: returns 1.
_targeted_command() {
  local cmd="$1" w out="" q prev="" keep cwd="$PROJECT_ROOT" abs s passed=0; shift
  local suites=()
  set -f # the words are inspected, never expanded
  for w in $cmd; do
    keep=1
    case "$w" in
      *[\*\?\[]*) keep=0 ;;
      *)
        case "$w" in /*) abs="$w" ;; *) abs="$cwd/$w" ;; esac
        if [ "$prev" != cd ] && [ -e "$abs" ]; then
          if [ -d "$abs" ]; then keep=0
          elif grep -qE "$TEST_FILE_RE" <<<"$w"; then
            # a .sh that is test-shaped only by its directory (`bash test/run.sh`) is the runner's wrapper
            case "$w" in *.sh) grep -qE '(\.bats$|\.(test|spec)\.|(^|/)test_[^/]*$|_test\.[A-Za-z0-9]+$)' <<<"$w" && keep=0 ;; *) keep=0 ;; esac
          fi
        fi ;;
    esac
    # program position, or the target of `cd`: always the runner's own
    case "$prev" in ""|"&&"|";"|"||"|"|"|cd) keep=1 ;; esac
    [ "$prev" = cd ] && case "$w" in /*) cwd="$w" ;; *) cwd="$cwd/$w" ;; esac
    if [ "$keep" = 1 ]; then
      out="$out $w"
    else
      s="${w//[\'\"]/}" # a quoted glob (`'src/**/*.test.ts'`) is matched without its quotes
      case "$s" in /*) ;; *) s="$cwd/$s" ;; esac
      suites+=("$(_norm_path "$s")")
    fi
    prev="$w"
  done
  set +f
  for q in "$@"; do
    abs="$PROJECT_ROOT/$q"
    if [ "${#suites[@]}" -gt 0 ]; then
      keep=0
      for s in "${suites[@]}"; do
        if _suite_selects "$s" "$(_norm_path "$abs")"; then keep=1; break; fi
      done
      [ "$keep" = 1 ] || continue
    fi
    case "$abs" in "$cwd"/*) q="${abs#"$cwd"/}" ;; *) [ "$cwd" = "$PROJECT_ROOT" ] || q="$abs" ;; esac
    out="$out $(printf '%q' "$q")"
    passed=1
  done
  [ "$passed" = 1 ] || return 1
  printf '%s' "${out# }"
}

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/solve-issue-checks.XXXXXX")"
OVERALL=0
for key in "${KEYS[@]}"; do
  cmd="$(_cached "$key")"
  if [ -z "$cmd" ]; then
    echo "$key: NOT RUN: no command found"
    continue
  fi
  if [ "${CREW_DEFER_FULL_CHECKS:-}" = 1 ] && [ "$key" != typecheck ] && [ "$key" != lint ] \
    && ! { [ "$TARGETED" = 1 ] && [ "$key" = test ]; }; then
    echo "$key: deferred — CREW_DEFER_FULL_CHECKS=1; the verify gate runs it on this branch"
    continue
  fi
  label=""
  if [ "${CREW_DEFER_FULL_CHECKS:-}" = 1 ] && [ "$TARGETED" = 1 ] && [ "$key" = test ]; then
    if ! _takes_test_files "$cmd"; then
      echo "test: deferred (the test command takes no test file arguments) — nothing ran; the verify gate runs the full suite"
      continue
    fi
    mapfile -t tfiles < <(_changed_tests)
    if [ "${#tfiles[@]}" -eq 0 ]; then
      echo "test: deferred (no changed test files) — nothing ran; the verify gate runs the full suite"
      continue
    fi
    if ! cmd="$(_targeted_command "$cmd" "${tfiles[@]}")"; then
      echo "test: deferred (no changed test file the test command's suite arguments select) — nothing ran; the verify gate runs the full suite"
      continue
    fi
    label=1
  fi
  log="$LOG_DIR/$key.log"
  echo "=== $key: $cmd"
  before="$(_tree_state)"
  # stdin from /dev/null: a `docker compose run` would otherwise read the rest of this loop. Logged
  # through a pipe: on overlayfs a check writing straight to a file under /tmp can hang forever.
  bash "$RUN_SCRIPT" --project-root "$PROJECT_ROOT" ${MAIN_ROOT:+--main-root "$MAIN_ROOT"} -- "$cmd" \
    </dev/null 2>&1 | cat >"$log"
  rc=${PIPESTATUS[0]}
  after="$(_tree_state)"
  changed=""
  [ "$before" = "$after" ] || changed="$(_changed_files "$before" "$after")"
  tail -n "$TAIL_LINES" "$log"
  if [ -n "$changed" ]; then
    echo "$key: modified files: $changed — the check rewrote them: run it, commit the result, and re-run (a check that rewrites files on every run needs a non-mutating command in .coding-crew/dev-commands.json)"
    echo "$key: fail (exit $rc, modified files)"
    OVERALL=1
  elif [ "$rc" -eq 0 ]; then
    echo "$key: pass${label:+ (targeted)}"
  else
    echo "$key: fail (${label:+targeted, }exit $rc)"
    OVERALL=1
  fi
  echo "$key: log: $log"
done

if [ "$OVERALL" -eq 0 ]; then echo "CHECKS: pass"; else echo "CHECKS: fail"; fi
exit "$OVERALL"
