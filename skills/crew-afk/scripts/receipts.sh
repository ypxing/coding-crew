#!/usr/bin/env bash
set -uo pipefail

# receipts.sh — gate receipts: facts on disk the merge and close steps require, so a skipped gate
# refuses the merge instead of leaving no trace. Usage: receipts.sh <write|clear|path|check> <verify|ac> (see _usage).
# verify.json (written by verify-worktree.sh, pass or fail) counts only as a `pass` at the branch's tip.
# ac.ok (written here once review returns all-met) holds the reviewed commit; `check ac` tests only that
# it exists, since by close time the branch may be gone, and --at-tip also requires the tip.
# CREW_RECEIPTS=off disables checking (writes still happen); never set it in a sprint.

_usage() {
  cat >&2 <<'EOF'
Usage:
  receipts.sh write ac           --dir    <worktree-path>
  receipts.sh write ac           --branch <branch> [--sha <reviewed-commit>]
  receipts.sh clear <verify|ac>  --dir    <worktree-path> [--stem <n>-<slug>]
  receipts.sh path  <verify|ac>  --dir    <worktree-path> [--stem <n>-<slug>]
  receipts.sh check verify       --branch <branch>
  receipts.sh check ac           --issue  <issue-file-path>
  receipts.sh check ac           --branch <branch> [--at-tip]
EOF
}

receipts_enabled() {
  [ "${CREW_RECEIPTS:-on}" != "off" ]
}

# shellcheck source=main-root.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main-root.sh"
_main_root_of() { main_root "$1"; }

# _split_crew_branch <branch> — "<feature-slug> <issue-slug>"; fails for anything else.
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

# _dispatch_issue_dir <dispatch-dir> <issue-slug> [<stem>] — a lookup by bare slug (a branch never
# carries the issue number) finds `<digits>-<slug>` first, else bare `<slug>`.
_dispatch_issue_dir() {
  local dispatch="$1" slug="$2" stem="${3:-}"
  if [ -n "$stem" ]; then echo "$dispatch/$stem"; return; fi
  local d
  for d in "$dispatch"/[0-9]*-"$slug"; do
    [ -d "$d" ] || continue
    if basename "$d" | grep -qE "^[0-9]+-$(printf '%s' "$slug" | sed 's/[.[\*^$]/\\&/g')$"; then
      echo "$d"; return
    fi
  done
  echo "$dispatch/$slug"
}

# _receipt_file <main-root> <feature-slug> <issue-slug> <kind> [<stem>]
_receipt_file() {
  local dispatch="$1/.scratch/$2/dispatch"
  local dir
  dir=$(_dispatch_issue_dir "$dispatch" "$3" "${5:-}")
  if [ "$4" = "ac" ]; then echo "$dir/ac.ok"; return; fi
  echo "$dir/verify.json"
}

# issue_slug_of <issue-file-path> — the orchestrator's ISSUE_SLUG derivation, which ties an ac
# receipt to one issue rather than to whichever branch was verified last.
issue_slug_of() {
  local base
  base=$(basename "$1")
  base="${base%.md}"
  echo "$base" | sed -E 's/^[0-9]+[-_]?//'
}


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
SHA=""
AT_TIP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --at-tip) AT_TIP=1; shift ;;
    --dir|--branch|--issue|--stem|--sha)
      # Guard: under `set -u` a bare flag would abort on an unbound variable.
      if [ $# -lt 2 ]; then echo "ERROR: $1 requires a value" >&2; exit 1; fi
      case "$1" in
        --dir) DIR="$2" ;;
        --branch) BRANCH="$2" ;;
        --issue) ISSUE="$2" ;;
        --stem) STEM="$2" ;;
        --sha) SHA="$2" ;;
      esac
      shift 2
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; _usage; exit 1 ;;
  esac
done


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
        # --sha: the commit the reviewer was given, recorded instead of whatever the tip is now,
        # so a branch that moved during review fails `check ac --at-tip` as stale.
        if [ -n "$SHA" ]; then
          sha=$(git rev-parse --verify --quiet "${SHA}^{commit}" 2>/dev/null) || {
            echo "ERROR: no such commit: $SHA" >&2; exit 1; }
        fi
        [ -n "$sha" ] || { echo "ERROR: cannot record commit for $branch" >&2; exit 1; }
        # No `set -e`, and `check` tests only existence, so a failed write removes what `>` created.
        { mkdir -p "$(dirname "$file")" && echo "$sha" > "$file"; } 2>/dev/null || {
          rm -f "$file" 2>/dev/null
          echo "ERROR: cannot write $KIND receipt: $file" >&2; exit 1; }
        # The receipt is the only evidence the AC gate ran, so writing it is what gets traced.
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
          # Not a crew branch: outside this gate; failing it would be a false positive.
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
        # --branch: the github form, with no issue file to derive the slug from.
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

          # From the path, so this works after the branch is gone: .scratch/<feature>/issues/<state>/<file>.md
          state_dir=$(dirname "$ISSUE")
          feature_dir=$(dirname "$(dirname "$state_dir")")
          slug=$(issue_slug_of "$ISSUE")
          file="$(_dispatch_issue_dir "$feature_dir/dispatch" "$slug")/ac.ok"
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
