#!/usr/bin/env bash
set -uo pipefail

# receipts.sh — mechanical gate receipts for a crew-afk sprint
#
# Usage:
#   receipts.sh write <verify|ac>  --dir   <worktree-path>
#   receipts.sh write <verify|ac>  --branch <branch>            # cwd: main root
#   receipts.sh clear <verify|ac>  --dir   <worktree-path>
#   receipts.sh path  <verify|ac>  --dir   <worktree-path>
#   receipts.sh check verify       --branch <branch>            # cwd: main root
#   receipts.sh check ac           --issue  <issue-file-path>
#
#   --branch is the form to use once the worktree is gone: some variants remove a
#   worktree straight after its checks, then verify acceptance criteria from the
#   main checkout, so the ac receipt has no worktree left to derive from.
#
# Why this exists
#   crew-afk's pipeline gates (check verification, then acceptance-criteria
#   verification) were prose-only instructions to the orchestrator. An
#   orchestrator that skipped them left no trace and nothing refused the merge,
#   so a branch with failing checks merged and a second issue was closed off the
#   first issue's branch. A receipt turns each gate into a fact on disk that the
#   mechanical steps downstream can require.
#
# What a receipt is
#   <main-root>/.scratch/<feature-slug>/dispatch/<issue-slug>.<kind>.ok
#   containing the commit SHA that was gated. Same directory as the worker
#   reports, so a sprint's evidence stays in one place.
#
#   The SHA matters for `verify`: it binds the receipt to the exact tree that
#   passed the checks, so commits pushed after verification cannot ride in on an
#   earlier pass. `ac` receipts are only checked for existence — by close time
#   the branch may already be merged and deleted, so there is no tip to compare.
#
# Escape hatch
#   CREW_RECEIPTS=off disables *checking* (writes still happen). For debugging
#   and for callers driving these scripts outside a sprint. Never set it in a
#   sprint: it re-opens exactly the hole this file closes.

_usage() {
  cat >&2 <<'EOF'
Usage:
  receipts.sh write <verify|ac>  --dir    <worktree-path>
  receipts.sh write <verify|ac>  --branch <branch>
  receipts.sh clear <verify|ac>  --dir    <worktree-path>
  receipts.sh path  <verify|ac>  --dir    <worktree-path>
  receipts.sh check verify       --branch <branch>
  receipts.sh check ac           --issue  <issue-file-path>
EOF
}

# receipts_enabled — false when the operator has explicitly disabled gating.
receipts_enabled() {
  [ "${CREW_RECEIPTS:-on}" != "off" ]
}

# _main_root_of <dir> — the main worktree's root, from any worktree.
#
# --git-common-dir points at the *shared* .git directory (the main worktree's),
# not the per-worktree one, which is what makes this work from inside a linked
# worktree. It can be relative, so resolve it from within the directory.
_main_root_of() {
  local dir="$1" common
  common=$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) : ;;
    *) common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")" ;;
  esac
  dirname "$common"
}

# _split_crew_branch <branch> — echoes "<feature-slug> <issue-slug>".
# Fails for anything that is not crew/<feature-slug>/<issue-slug>.
_split_crew_branch() {
  local branch="$1"
  case "$branch" in
    crew/*/*)
      local rest="${branch#crew/}"
      local feature="${rest%%/*}"
      local slug="${rest#*/}"
      if [ -z "$feature" ] || [ -z "$slug" ]; then return 1; fi
      echo "$feature $slug"
      ;;
    *) return 1 ;;
  esac
}

# _receipt_file <main-root> <feature-slug> <issue-slug> <kind>
_receipt_file() {
  echo "$1/.scratch/$2/dispatch/$3.$4.ok"
}

# issue_slug_of <issue-file-path> — filename minus leading digits and extension,
# matching the ISSUE_SLUG derivation the orchestrator uses to name branches.
# That shared derivation is the whole point: it is what ties an ac receipt to one
# specific issue rather than to whichever branch happened to be verified last.
issue_slug_of() {
  local base
  base=$(basename "$1")
  base="${base%.md}"
  echo "$base" | sed -E 's/^[0-9]+[-_]?//'
}

# ─── argument parsing ────────────────────────────────────────────────────────

ACTION="${1:-}"
KIND="${2:-}"
[ -n "$ACTION" ] && [ -n "$KIND" ] || { _usage; exit 1; }
shift 2

case "$KIND" in
  verify|ac) : ;;
  *) echo "ERROR: unknown receipt kind: $KIND (expected verify or ac)" >&2; exit 1 ;;
esac

DIR=""
BRANCH=""
ISSUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--branch|--issue)
      # Guard before reading $2: under `set -u` a bare flag would abort with an
      # unbound-variable error instead of the usage message.
      if [ $# -lt 2 ]; then echo "ERROR: $1 requires a value" >&2; exit 1; fi
      case "$1" in
        --dir) DIR="$2" ;;
        --branch) BRANCH="$2" ;;
        --issue) ISSUE="$2" ;;
      esac
      shift 2
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; _usage; exit 1 ;;
  esac
done

# ─── actions ─────────────────────────────────────────────────────────────────

case "$ACTION" in
  write|clear|path)
    if [ -z "$DIR" ] && [ -z "$BRANCH" ]; then
      echo "ERROR: $ACTION requires --dir <worktree-path> or --branch <branch>" >&2
      exit 1
    fi

    if [ -n "$DIR" ]; then
      [ -d "$DIR" ] || { echo "ERROR: directory does not exist: $DIR" >&2; exit 1; }
      branch=$(cd "$DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || {
        echo "ERROR: not a git worktree: $DIR" >&2; exit 1; }
      sha_source="$DIR"
    else
      # Resolve from the current repository (the main checkout).
      branch="$BRANCH"
      git rev-parse --verify --quiet "${branch}^{commit}" >/dev/null || {
        echo "ERROR: no such branch: $branch" >&2; exit 1; }
      sha_source=""
    fi

    # Test the split's output, not read's exit status: a herestring appends a
    # newline, so `read` succeeds on empty input and would leave both vars blank.
    split=$(_split_crew_branch "$branch") || split=""
    if [ -z "$split" ]; then
      echo "ERROR: branch '$branch' is not a crew/<feature>/<issue> branch — cannot place a receipt" >&2
      exit 1
    fi
    read -r feature slug <<<"$split"

    main_root=$(_main_root_of "${sha_source:-.}") || { echo "ERROR: cannot resolve main root" >&2; exit 1; }
    file=$(_receipt_file "$main_root" "$feature" "$slug" "$KIND")

    case "$ACTION" in
      path)
        echo "$file"
        ;;
      write)
        mkdir -p "$(dirname "$file")"
        if [ -n "$sha_source" ]; then
          sha=$(cd "$sha_source" && git rev-parse HEAD 2>/dev/null)
        else
          sha=$(git rev-parse "${branch}^{commit}" 2>/dev/null)
        fi
        [ -n "$sha" ] || { echo "ERROR: cannot record commit for $branch" >&2; exit 1; }
        echo "$sha" > "$file"
        echo "RECEIPT: wrote $KIND receipt for $slug ($file)"
        ;;
      clear)
        rm -f "$file"
        echo "RECEIPT: cleared $KIND receipt for $slug"
        ;;
    esac
    ;;

  check)
    if ! receipts_enabled; then
      echo "RECEIPT: checking disabled (CREW_RECEIPTS=off)"
      exit 0
    fi

    case "$KIND" in
      verify)
        [ -n "$BRANCH" ] || { echo "ERROR: check verify requires --branch <branch>" >&2; exit 1; }
        split=$(_split_crew_branch "$BRANCH") || split=""
        if [ -z "$split" ]; then
          # Not a crew branch: outside this gate's remit. Callers merge branches
          # that a sprint never produced, and failing those would be a false
          # positive, not a caught bug.
          echo "RECEIPT: $BRANCH is not a crew branch — gate not applicable"
          exit 0
        fi
        read -r feature slug <<<"$split"

        main_root=$(_main_root_of ".") || { echo "ERROR: not in a git repository" >&2; exit 1; }
        file=$(_receipt_file "$main_root" "$feature" "$slug" "verify")

        if [ ! -f "$file" ]; then
          echo "RECEIPT: $BRANCH has no verification receipt — refusing to treat it as verified." >&2
          echo "  Expected: $file" >&2
          echo "  Run: verify-worktree.sh --dir <worktree> (and only merge if it exits 0)" >&2
          exit 1
        fi

        recorded=$(cat "$file")
        actual=$(git rev-parse "${BRANCH}^{commit}" 2>/dev/null) || {
          echo "ERROR: cannot resolve branch: $BRANCH" >&2; exit 1; }
        if [ "$recorded" != "$actual" ]; then
          echo "RECEIPT: $BRANCH has a stale verification receipt — commits landed after verification." >&2
          echo "  verified: $recorded" >&2
          echo "  branch:   $actual" >&2
          echo "  Run: verify-worktree.sh --dir <worktree> again" >&2
          exit 1
        fi
        echo "RECEIPT: $BRANCH verified at $recorded"
        ;;

      ac)
        [ -n "$ISSUE" ] || { echo "ERROR: check ac requires --issue <issue-file-path>" >&2; exit 1; }

        # Derive both slugs from the path, so this works whether or not the
        # branch still exists: .scratch/<feature>/issues/<state>/<file>.md
        state_dir=$(dirname "$ISSUE")
        feature_dir=$(dirname "$(dirname "$state_dir")")
        slug=$(issue_slug_of "$ISSUE")
        file="$feature_dir/dispatch/$slug.ac.ok"

        if [ ! -f "$file" ]; then
          echo "RECEIPT: $(basename "$ISSUE") has no acceptance-criteria receipt — refusing to close it." >&2
          echo "  Expected: $file" >&2
          echo "  A receipt is written only for the branch crew/<feature>/$slug after its own" >&2
          echo "  acceptance-criteria check returns 'AC: all-met'. Another issue's receipt will not do." >&2
          exit 1
        fi
        echo "RECEIPT: $(basename "$ISSUE") criteria-verified"
        ;;
    esac
    ;;

  *)
    echo "ERROR: unknown action: $ACTION" >&2
    _usage
    exit 1
    ;;
esac
