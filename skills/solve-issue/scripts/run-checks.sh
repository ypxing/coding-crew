#!/usr/bin/env bash
# run-checks.sh — run every check .coding-crew/dev-commands.json names, each through
# dep-install's run.sh, and report each one.
#
# Usage:
#   bash scripts/run-checks.sh --project-root <path> --main-root <path> --dep-scripts <dir> [--targeted]
#
# --targeted only means something under CREW_DEFER_FULL_CHECKS=1; without it the full suite runs
# as always. CREW_BASE_REF names the ref to take the merge-base against (default: origin/HEAD,
# origin/main, main, master — the first that resolves).
#
# Order: typecheck, lint, test, then every other check key with a command (coverage,
# integration, …) in file order — the same set, in the same order, crew-afk's verify gate runs,
# so a worker that sees every line pass has seen what the gate will see.
#
# Prints per check:
#   <key>: pass | <key>: fail (exit N)     then the tail of its output; the full log path
#   <key>: NOT RUN: no command found       the cache's `null` — its own answer, not a gap to fill
#   <key>: modified files: <list> — …      then `<key>: fail (…)`: the check rewrote tracked or
#                                          untracked files (an auto-fixing lint) — the human
#                                          commits the rewrite; not something to revert and re-run
#   test: pass (targeted) | test: fail (targeted, exit N)
#                                          with CREW_DEFER_FULL_CHECKS=1 and --targeted: only the test
#                                          files changed on the branch since its merge-base (plus
#                                          uncommitted ones) ran, as the cached test command with its
#                                          path/glob arguments swapped for those files
#   test: deferred (no changed test files) with --targeted and no changed test file: nothing ran
#   test: deferred (the test command takes no test file arguments)
#                                          with --targeted and a runner such as make, go or cargo
#   <key>: deferred …                      with CREW_DEFER_FULL_CHECKS=1 only: every check other than
#                                          typecheck and lint (test, coverage, …) is not run here — the
#                                          verify gate runs it; report the check as `deferred`
# and last, one of:
#   CHECKS: pass                           exit 0
#   CHECKS: fail                           exit 1
#   DISCOVER                               exit 3 — no usable cache: discover the commands
#                                          (references/verification.md), persist them, re-run
#
# The cache is read from MAIN_ROOT — resolved from --git-common-dir when --main-root is empty,
# so a lost MAIN_ROOT still finds the shared cache instead of concluding there is none.

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

# _cached <key> — its command; empty for `null` or an absent key. Parsed the way
# verify-worktree.sh's _load_cached_command parses it, so both read the same command.
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

# A check must leave the tree as it found it — the same rule, and the same line, as crew-afk's
# verify gate: `git status --porcelain` before and after, and a differing line names a file the
# check touched. Dirt already there is in the before snapshot, so it is not blamed on the check.
_tree_state() {
  git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | LC_ALL=C sort
}
_changed_files() {
  LC_ALL=C comm -3 <(printf '%s\n' "$1") <(printf '%s\n' "$2") \
    | sed -E 's/^\t//; s/^...//' \
    | awk 'NF && !seen[$0]++ { printf "%s%s", (n++ ? ", " : ""), $0 }'
}

# A test file by its own name (a file under tests/ may be a helper or fixture): bats, *.test.* /
# *.spec.*, pytest's test_*.py, *_test.* (go, python), *_spec.rb, and jest's __tests__/ sources.
TEST_FILE_RE='(\.bats$|\.(test|spec)\.[A-Za-z0-9]+$|(^|/)test_[^/]*\.py$|_test\.[A-Za-z0-9]+$|_spec\.rb$|(^|/)__tests__/[^/]+\.[cm]?[jt]sx?$)'
# Never a suite file, whatever its name: test data and helpers.
NOT_TEST_RE='(^|/)(fixtures?|helpers?|__fixtures__|__snapshots__|testdata)/'
# Runners that take no test file arguments (or treat them as something else): a targeted run
# through them would not run the changed tests, so they are deferred to the verify gate.
NO_FILE_ARGS_RE='^(make|gmake|go|cargo|gradle|gradlew|\./gradlew|mvn|mvnw|\./mvnw|dotnet|rake|ctest|tox|nox)$'

# _changed_tests — existing test files changed on this branch since its merge-base, plus
# uncommitted and untracked ones, one per line.
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

# _takes_test_files <cached test command> — false when a program the command runs (the first word
# of each `&&`/`;`/`|` segment, `cd` segments aside) is a runner in NO_FILE_ARGS_RE.
_takes_test_files() {
  local w prev=""
  set -f
  for w in $1; do
    case "$prev" in ""|"&&"|";"|"||"|"|")
      if [ "$w" != cd ] && printf '%s\n' "$w" | grep -qE "$NO_FILE_ARGS_RE"; then set +f; return 1; fi ;;
    esac
    prev="$w"
  done
  set +f
  return 0
}

# _targeted_command <cached test command> <files…> — the test command with only its suite
# path/glob arguments replaced by the files. The runner's own words stay: the program, a `cd`
# target, and a repo script it runs (`bash scripts/test.sh`). A word is a suite argument when it
# has a glob character, or names an existing directory or test file (not in program position).
# After a `cd`, words resolve from its target, and the files are passed relative to it (absolute
# when outside it).
_targeted_command() {
  local cmd="$1" w out="" q prev="" keep cwd="$PROJECT_ROOT" abs; shift
  set -f # the words are inspected, never expanded
  for w in $cmd; do
    keep=1
    case "$w" in
      *[\*\?\[]*) keep=0 ;;
      *)
        case "$w" in /*) abs="$w" ;; *) abs="$cwd/$w" ;; esac
        if [ "$prev" != cd ] && [ -e "$abs" ]; then
          if [ -d "$abs" ]; then keep=0
          elif printf '%s\n' "$w" | grep -qE "$TEST_FILE_RE"; then
            # a shell script that is test-shaped only by its directory (`bash test/run.sh`) is the
            # runner's wrapper, not a suite file
            case "$w" in *.sh) printf '%s\n' "$w" | grep -qE '(\.bats$|\.(test|spec)\.|(^|/)test_[^/]*$|_test\.[A-Za-z0-9]+$)' && keep=0 ;; *) keep=0 ;; esac
          fi
        fi ;;
    esac
    # program position, or the target of `cd`: always the runner's own
    case "$prev" in ""|"&&"|";"|"||"|"|"|cd) keep=1 ;; esac
    [ "$prev" = cd ] && case "$w" in /*) cwd="$w" ;; *) cwd="$cwd/$w" ;; esac
    [ "$keep" = 1 ] && out="$out $w"
    prev="$w"
  done
  set +f
  for q in "$@"; do
    abs="$PROJECT_ROOT/$q"
    case "$abs" in "$cwd"/*) q="${abs#"$cwd"/}" ;; *) [ "$cwd" = "$PROJECT_ROOT" ] || q="$abs" ;; esac
    out="$out $(printf '%q' "$q")"
  done
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
    cmd="$(_targeted_command "$cmd" "${tfiles[@]}")"
    label=1
  fi
  log="$LOG_DIR/$key.log"
  echo "=== $key: $cmd"
  before="$(_tree_state)"
  # stdin from /dev/null: a `docker compose run` would otherwise read the rest of this loop.
  bash "$RUN_SCRIPT" --project-root "$PROJECT_ROOT" ${MAIN_ROOT:+--main-root "$MAIN_ROOT"} -- "$cmd" \
    </dev/null >"$log" 2>&1
  rc=$?
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
