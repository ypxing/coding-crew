#!/usr/bin/env bash
set -uo pipefail

# receipts.sh — mechanical gate receipts for a crew-afk sprint
#
# Usage:
#   receipts.sh write ac           --dir   <worktree-path>
#   receipts.sh write ac           --branch <branch>            # cwd: main root
#   receipts.sh clear <verify|ac>  --dir   <worktree-path> [--stem <n>-<slug>]
#   receipts.sh path  <verify|ac>  --dir   <worktree-path> [--stem <n>-<slug>]
#   receipts.sh check verify       --branch <branch>            # cwd: main root
#   receipts.sh check ac           --issue  <issue-file-path>   # local backend
#   receipts.sh check ac           --branch <branch>            # github backend, cwd: main root
#   receipts.sh check ac           --branch <branch> --at-tip   # cwd: main root
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
#   Both live in <main-root>/.scratch/<feature-slug>/dispatch/, beside the worker
#   reports, so a sprint's evidence stays in one place.
#
#   verify: <n>-<slug>.verify.json, verify-worktree.sh's own record of the run (the
#   bare <slug>.verify.json when no --stem was given). It is written by that script,
#   never here, pass or fail; `check verify` accepts it only with a `pass` verdict and
#   a `commit` equal to the branch's tip, so commits pushed after verification cannot
#   ride in on an earlier pass. `check verify --branch` knows only the slug, so it
#   finds the record by `<digits>-<slug>` or bare `<slug>`.
#
#   ac: <slug>.ac.ok, written here once review returned all-met, holding the reviewed
#   commit. `check ac` tests only its existence — by close time the branch may already be
#   merged and deleted, so there is no tip to compare. `--at-tip` also requires that commit
#   to be the branch's tip: what a retry asks before skipping a review it already passed.
#
#   Writing an `ac` receipt also emits the ACVERIFY trace line, because the receipt
#   is the only evidence that gate ran. Verify receipts are traced by
#   verify-worktree.sh, which is the script that runs those checks.
#
# Escape hatch
#   CREW_RECEIPTS=off disables *checking* (writes still happen). For debugging
#   and for callers driving these scripts outside a sprint. Never set it in a
#   sprint: it re-opens exactly the hole this file closes.

_usage() {
  cat >&2 <<'EOF'
Usage:
  receipts.sh write ac           --dir    <worktree-path>
  receipts.sh write ac           --branch <branch>
  receipts.sh clear <verify|ac>  --dir    <worktree-path> [--stem <n>-<slug>]
  receipts.sh path  <verify|ac>  --dir    <worktree-path> [--stem <n>-<slug>]
  receipts.sh check verify       --branch <branch>
  receipts.sh check ac           --issue  <issue-file-path>
  receipts.sh check ac           --branch <branch> [--at-tip]
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
  # --path-format=absolute: without it, plain `--git-common-dir` can come back cwd-relative.
  # It still isn't enough on its own — git's own idea of "absolute" on Windows is a bare
  # drive-letter path like "C:/Users/...", which doesn't start with "/", so the *)-branch
  # below needs its own drive-letter case or it wrongly treats that as relative and mangles it.
  common=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*|[A-Za-z]:*) : ;;
    *) common="$dir/$common" ;;
  esac
  # Re-canonicalize through this shell's own `pwd -P` even though $common is already
  # absolute: git's drive-letter form ("C:/Users/...") is a different string than what
  # `pwd -P` prints for the same directory in this MSYS/git-bash shell ("/c/Users/..."),
  # and callers compare this return value against other `pwd -P`-resolved paths — leaving
  # it in git's own form breaks that string equality on Windows even though both name the
  # same directory.
  common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")"
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

# _receipt_file <main-root> <feature-slug> <issue-slug> <kind> [<stem>]
# A verify record with no stem is looked up: the `<digits>-<slug>` one the
# orchestrator wrote if there is one, else the bare-slug name.
_receipt_file() {
  local dispatch="$1/.scratch/$2/dispatch"
  if [ "$4" = "ac" ]; then echo "$dispatch/$3.ac.ok"; return; fi
  if [ -n "${5:-}" ]; then echo "$dispatch/$5.verify.json"; return; fi
  local f
  for f in "$dispatch"/[0-9]*-"$3".verify.json; do
    [ -f "$f" ] || continue
    if basename "$f" | grep -qE "^[0-9]+-$(printf '%s' "$3" | sed 's/[.[\*^$]/\\&/g')\.verify\.json$"; then
      echo "$f"; return
    fi
  done
  echo "$dispatch/$3.verify.json"
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
STEM=""
AT_TIP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --at-tip) AT_TIP=1; shift ;;
    --dir|--branch|--issue|--stem)
      # Guard before reading $2: under `set -u` a bare flag would abort with an
      # unbound-variable error instead of the usage message.
      if [ $# -lt 2 ]; then echo "ERROR: $1 requires a value" >&2; exit 1; fi
      case "$1" in
        --dir) DIR="$2" ;;
        --branch) BRANCH="$2" ;;
        --issue) ISSUE="$2" ;;
        --stem) STEM="$2" ;;
      esac
      shift 2
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; _usage; exit 1 ;;
  esac
done

# ─── actions ─────────────────────────────────────────────────────────────────

case "$ACTION" in
  write|clear|path)
    if [ "$ACTION" = "write" ] && [ "$KIND" = "verify" ]; then
      echo "ERROR: the verify record is written by verify-worktree.sh, not here" >&2
      exit 1
    fi
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
    file=$(_receipt_file "$main_root" "$feature" "$slug" "$KIND" "$STEM")

    case "$ACTION" in
      path)
        echo "$file"
        ;;
      write)
        if [ -n "$sha_source" ]; then
          sha=$(cd "$sha_source" && git rev-parse HEAD 2>/dev/null)
        else
          sha=$(git rev-parse "${branch}^{commit}" 2>/dev/null)
        fi
        [ -n "$sha" ] || { echo "ERROR: cannot record commit for $branch" >&2; exit 1; }
        # No `set -e` here: an unchecked failed write would still print "wrote" and exit 0.
        # `>` creates the file before the write can fail, and `check` only tests that the
        # file exists, so a failed write removes what it left behind.
        { mkdir -p "$(dirname "$file")" && echo "$sha" > "$file"; } 2>/dev/null || {
          rm -f "$file" 2>/dev/null
          echo "ERROR: cannot write $KIND receipt: $file" >&2; exit 1; }
        # An ac receipt is only ever written after an acceptance-criteria check returned
        # `AC: all-met`, so writing it *is* the event worth tracing. Tracing it here rather
        # than asking the orchestrator for a second `trace.sh ACVERIFY` call means the
        # marker cannot be emitted for a gate that never wrote a receipt, and costs no
        # extra round trip. verify receipts are already traced by verify-worktree.sh.
        if [ "$KIND" = "ac" ]; then
          bash "$(dirname "$0")/trace.sh" ACVERIFY "branch=$branch result=all-met" 2>/dev/null || true
        fi
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

        verdict=$(grep -o '"verdict"[[:space:]]*:[[:space:]]*"[a-z_]*"' "$file" 2>/dev/null | head -1 | sed -E 's/.*"([a-z_]*)"$/\1/')
        recorded=$(grep -o '"commit"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "$file" 2>/dev/null | head -1 | sed -E 's/.*"([0-9a-f]*)"$/\1/')
        if [ "$verdict" != "pass" ]; then
          echo "RECEIPT: $BRANCH did not pass verification (verdict: ${verdict:-unreadable}) — refusing to treat it as verified." >&2
          echo "  Record: $file" >&2
          exit 1
        fi
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
        # --branch is the github-backend form: there is no issue file path to derive a
        # slug/feature dir from (see close-issue.sh's github branch), so this splits the
        # branch itself — the exact same derivation `write ac --branch` already used to
        # place the receipt in the first place, and `check verify --branch` above already
        # uses for the same reason. --issue stays the local form, unchanged.
        if [ -n "$BRANCH" ]; then
          split=$(_split_crew_branch "$BRANCH") || split=""
          if [ -z "$split" ]; then
            echo "ERROR: branch '$BRANCH' is not a crew/<feature>/<issue> branch — cannot check a receipt" >&2
            exit 1
          fi
          read -r feature slug <<<"$split"
          main_root=$(_main_root_of ".") || { echo "ERROR: not in a git repository" >&2; exit 1; }
          file=$(_receipt_file "$main_root" "$feature" "$slug" "ac")
          label="$BRANCH"
        else
          [ -n "$ISSUE" ] || { echo "ERROR: check ac requires --issue <issue-file-path> or --branch <branch>" >&2; exit 1; }

          # Derive both slugs from the path, so this works whether or not the
          # branch still exists: .scratch/<feature>/issues/<state>/<file>.md
          state_dir=$(dirname "$ISSUE")
          feature_dir=$(dirname "$(dirname "$state_dir")")
          slug=$(issue_slug_of "$ISSUE")
          file="$feature_dir/dispatch/$slug.ac.ok"
          label=$(basename "$ISSUE")
        fi

        if [ ! -f "$file" ]; then
          echo "RECEIPT: $label has no acceptance-criteria receipt — refusing to close it." >&2
          echo "  Expected: $file" >&2
          echo "  A receipt is written only for the branch crew/<feature>/$slug after its own" >&2
          echo "  acceptance-criteria check returns 'AC: all-met'. Another issue's receipt will not do." >&2
          exit 1
        fi
        if [ "$AT_TIP" -eq 1 ]; then
          [ -n "$BRANCH" ] || { echo "ERROR: --at-tip requires --branch <branch>" >&2; exit 1; }
          recorded=$(head -n 1 "$file" 2>/dev/null | tr -d '[:space:]')
          actual=$(git rev-parse "${BRANCH}^{commit}" 2>/dev/null) || {
            echo "ERROR: cannot resolve branch: $BRANCH" >&2; exit 1; }
          if [ "$recorded" != "$actual" ]; then
            echo "RECEIPT: $BRANCH was reviewed at ${recorded:-an unknown commit}, not at its tip $actual." >&2
            exit 1
          fi
          echo "RECEIPT: $label criteria-verified at $recorded"
          exit 0
        fi
        echo "RECEIPT: $label criteria-verified"
        ;;
    esac
    ;;

  *)
    echo "ERROR: unknown action: $ACTION" >&2
    _usage
    exit 1
    ;;
esac
