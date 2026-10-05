#!/usr/bin/env bash
set -euo pipefail

# state.sh — the sprint's bookkeeping, as a script instead of as prose.
#
# Every round the orchestrator has to remember which slugs completed, which branches
# were retained and why, which issues are blocked, and which categories had no
# discoverable check command. That list used to live in the prompt as a set of raw jq
# one-liners plus an instruction to "append to all_merged / all_partial / all_blocked",
# which meant a long sprint could silently lose an entry and then report a branch as
# cleaned up that was never deleted. It is all mechanical, so it lives here.
#
# Usage:
#   state.sh model <alias>
#   state.sh attempt --slug <slug> --n <n>
#   state.sh complete --slug <slug> --branch <branch>
#   state.sh retain   --slug <slug> --branch <branch> --reason <reason> [--fingerprint <sha256>]
#   state.sh blocked  --slug <slug> [--branch <branch>] [--reason <text>] [--number <n>]
#   state.sh coverage-gap --slug <slug> --categories <lint,typecheck>
#   state.sh coverage-clear --slug <slug>
#   state.sh deviation --slug <slug> --reason <text>
#   state.sh dispatch-cost [--cost <usd>] [--duration-ms <ms>] [--turns <n>]
#                          [--slug <slug> --role <role> --attempt <n>]
#                          [--session-id <id>] [--context-tokens <n>] [--head <sha>]
#                          [--cost-unknown --tokens <n>]
#   state.sh run-start --id <run-id>
#   state.sh run-end --reason <text> --code <n>   (why this run ended: every orchestrator exit path)
#   state.sh baseline [--slot baseline|integration] --commit <sha> --verdict <pass|fail>
#   state.sh verified-tree --tree <git tree sha>   (a per-issue verify passed this tree)
#   state.sh feature-reviewed --tip <sha>          (a feature review wrote a report over the branch up to this tip)
#   state.sh feature-review-promoted               (a feature review created a fix issue: one more toward the per-feature cap)
#   state.sh resume --slug <slug>
#   state.sh retention --slug <slug>
#   state.sh get <merged|retained|completed|partial|blocked|model|round|feature-slug|feature-review-promotions|runs|previous-exit|state-file>
#   state.sh show
#
# Common flags: [--feature-slug <slug>] [--state-file <path>]
#
# `retain` is the single entry point for every branch that must survive the sprint:
# partial work, a failed verification, unmet acceptance criteria, a failed merge, or a
# blocked issue. The reason string is what the summary prints, and `get retained` is what
# feeds cleanup-worktrees.sh --retain, so a branch recorded here cannot be deleted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "state.sh: $1" >&2; exit 1; }

trace() { bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null || true; }

usage() {
  sed -n '/^# Usage:/,/^# `retain`/p' "$0" >&2
  exit 1
}

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift

# --- state file resolution ----------------------------------------------------
# Explicit flags win, then the environment exported by sprint.env, then a lookup
# through sprint.env itself. Never a `ls .scratch/*/sprint-state.json | head -1` glob:
# that picks the alphabetically-first feature, which is the wrong sprint in any repo
# that has ever run two.
FEATURE_SLUG_ARG=""
STATE_FILE_ARG=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --feature-slug) FEATURE_SLUG_ARG="${2:-}"; shift 2 ;;
    --state-file) STATE_FILE_ARG="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

resolve_state_file() {
  if [ -n "$STATE_FILE_ARG" ]; then
    printf '%s\n' "$STATE_FILE_ARG"; return 0
  fi
  if [ -n "$FEATURE_SLUG_ARG" ]; then
    printf '%s\n' "$MAIN_ROOT/.scratch/$FEATURE_SLUG_ARG/sprint-state.json"; return 0
  fi
  if [ -n "${STATE_FILE:-}" ]; then
    printf '%s\n' "$STATE_FILE"; return 0
  fi
  if [ -f "$MAIN_ROOT/.scratch/sprint.env" ]; then
    # shellcheck disable=SC1091
    . "$MAIN_ROOT/.scratch/sprint.env"
    if [ -n "${STATE_FILE:-}" ]; then printf '%s\n' "$STATE_FILE"; return 0; fi
  fi
  return 1
}

SF=$(resolve_state_file) || die "cannot resolve the sprint state file — pass --feature-slug or source .scratch/sprint.env"
[ -f "$SF" ] || die "sprint state file not found: $SF (run session-init.sh first)"
command -v jq >/dev/null 2>&1 || die "jq is required"

edit_state() {
  local tmp="$SF.tmp.$$"
  jq "$@" "$SF" > "$tmp" && mv "$tmp" "$SF"
}

flag() {
  # flag <name> <default> "$@" — read --name from the remaining args
  local want="$1" out="$2"; shift 2
  while [ $# -gt 0 ]; do
    if [ "$1" = "--$want" ]; then out="${2:-}"; fi
    shift
  done
  printf '%s\n' "$out"
}

csv() { jq -r "$1 | join(\",\")" "$SF"; }

case "$CMD" in
  model)
    alias_name="${1:?state.sh model <alias>}"
    edit_state --arg m "$alias_name" '.model = $m'
    trace MODEL "resolved=$alias_name"
    echo "MODEL: $alias_name"
    ;;

  attempt)
    # Records one attempt at one issue, across the whole sprint (not a batch) — the
    # scheduler (loop.mjs's runOne) calls this exactly once per dispatch, at claim time,
    # before runWorker/runHousekeeping run, so `.attempts[slug]` mirrors every pass
    # including the one that finally completes. `.rounds` (still read by crew-summary.sh
    # as "Rounds: N") becomes the highest count any single issue has reached this run, with
    # no other meaning attached to "round" any more.
    #
    # `--n` is supplied by the caller, not derived from `.attempts[slug]` here — the real
    # counter lives in the orchestrator's own in-memory Sprint instance (see sprint.mjs's
    # bumpAttempt), reset every invocation on purpose: a persisted, ever-growing count
    # would make crew-summary.sh's "resolve blockers and re-run" recovery advice a lie, by
    # permanently refusing to retry whatever it told a human to go fix. This command is a
    # write-only mirror for reporting, never read back to decide anything.
    slug=$(flag slug "" "$@")
    n=$(flag n "" "$@")
    [ -n "$slug" ] || die "attempt requires --slug"
    [ -n "$n" ] || die "attempt requires --n"
    edit_state --arg s "$slug" --argjson n "$n" '
      .attempts[$s] = $n
      | .round = $n
      | .rounds = ([.rounds // 0, $n] | max)'
    trace ATTEMPT "slug=$slug n=$n"
    echo "ATTEMPT: slug=$slug n=$n"
    ;;

  complete)
    slug=$(flag slug "" "$@"); branch=$(flag branch "" "$@")
    [ -n "$slug" ] || die "complete requires --slug"
    [ -n "$branch" ] || die "complete requires --branch"
    # Retention is cleared here so a stale branch is never offered for resume, and so
    # the branch moves out of cleanup's --retain list into its --merged list.
    edit_state --arg s "$slug" --arg b "$branch" '
      .completed_slugs = ((.completed_slugs // []) + [$s] | unique)
      | .merged_branches = ((.merged_branches // []) + [$b] | unique)
      | .retained_branches = ((.retained_branches // {}) | del(.[$s]))
      | .retention = ((.retention // {}) | del(.[$s]))
      | .blocked_slugs = ((.blocked_slugs // []) - [$s])
      | .blocked_labelled = ((.blocked_labelled // {}) | del(.[$s]))'
    trace STATE "complete slug=$slug branch=$branch"
    echo "STATE: complete slug=$slug branch=$branch"
    ;;

  retain)
    slug=$(flag slug "" "$@"); branch=$(flag branch "" "$@"); reason=$(flag reason "" "$@")
    fingerprint=$(flag fingerprint "" "$@")
    [ -n "$slug" ] || die "retain requires --slug"
    [ -n "$branch" ] || die "retain requires --branch"
    [ -n "$reason" ] || die "retain requires --reason (partial | verification-failed | criteria-unmet | review-not-run | merge-failed | blocked)"
    # --fingerprint: a hash of the issue's What to build / Acceptance criteria when the
    # attempt ended; a later run that sees a different one knows a human edited the issue.
    edit_state --arg s "$slug" --arg b "$branch" --arg r "$reason" --arg f "$fingerprint" '
      .retained_branches[$s] = $b
      | .retention[$s] = ({branch: $b, reason: $r} + (if $f == "" then {} else {fingerprint: $f} end))
      | .completed_slugs = ((.completed_slugs // []) - [$s])
      | .merged_branches = ((.merged_branches // []) - [$b])'
    trace --level warn STATE "retain slug=$slug branch=$branch reason=$reason"
    echo "STATE: retain slug=$slug branch=$branch reason=$reason"
    ;;

  blocked)
    slug=$(flag slug "" "$@"); branch=$(flag branch "" "$@"); reason=$(flag reason "blocked" "$@")
    number=$(flag number "" "$@"); fingerprint=$(flag fingerprint "" "$@")
    [ -n "$slug" ] || die "blocked requires --slug"
    edit_state --arg s "$slug" --arg r "$reason" '.blocked_slugs = ((.blocked_slugs // []) + [$s] | unique) | .blocked_reasons[$s] = $r'
    # --number: the issue got the `blocked` label; crew-summary prints how to remove it.
    if [ -n "$number" ]; then
      edit_state --arg s "$slug" --argjson n "$number" '.blocked_labelled = ((.blocked_labelled // {}) + {($s): $n})'
    fi
    if [ -n "$branch" ]; then
      edit_state --arg s "$slug" --arg b "$branch" --arg r "blocked — $reason" --arg f "$fingerprint" '
        .retained_branches[$s] = $b
        | .retention[$s] = ({branch: $b, reason: $r} + (if $f == "" then {} else {fingerprint: $f} end))'
    fi
    trace --level error STATE "blocked slug=$slug${branch:+ branch=$branch}"
    echo "STATE: blocked slug=$slug${branch:+ branch=$branch}"
    ;;

  coverage-gap)
    slug=$(flag slug "" "$@"); cats=$(flag categories "" "$@")
    [ -n "$slug" ] || die "coverage-gap requires --slug"
    [ -n "$cats" ] || die "coverage-gap requires --categories"
    edit_state --arg s "$slug" --arg c "$cats" '.coverage_gaps[$s] = $c'
    trace --level warn STATE "coverage-gap slug=$slug categories=$cats"
    echo "STATE: coverage-gap slug=$slug categories=$cats"
    ;;

  deviation)
    slug=$(flag slug "" "$@"); reason=$(flag reason "" "$@")
    [ -n "$slug" ] || die "deviation requires --slug"
    [ -n "$reason" ] || die "deviation requires --reason"
    edit_state --arg s "$slug" --arg r "$reason" '.deviations[$s] = ((.deviations[$s] // []) + [$r] | unique)'
    trace --level warn DEVIATION "slug=$slug $reason"
    echo "STATE: deviation slug=$slug"
    ;;

  coverage-clear)
    slug=$(flag slug "" "$@")
    [ -n "$slug" ] || die "coverage-clear requires --slug"
    edit_state --arg s "$slug" 'del(.coverage_gaps[$s])'
    echo "STATE: coverage-clear slug=$slug"
    ;;

  dispatch-cost)
    # Accumulates every dispatch's cost/duration/turns into one sprint-wide running total —
    # additive, unlike attempt's `max`, since this sums across every dispatch the sprint
    # makes (coder, reviewer, triage, every retry), not one issue's own latest attempt.
    # Claude-only for now (see extractResultMeta in dispatch.mjs); 0 for every other
    # platform, which this is a no-op for.
    #
    # With --slug/--role it is also one entry in `.dispatches`, tagged with the run it
    # belongs to (run-start), so the summary can say what *this* run cost, by role and by
    # first attempt vs retry — the totals above span every run of the feature. The coder's
    # entry also keeps its session id, context size and the branch tip it left, which is
    # what a later fix round needs to decide whether that session can be resumed.
    #
    # --cost-unknown marks a dispatch that ended with no `result` event (killed on timeout):
    # its cost is not zero, it is not known, so it adds nothing to the cost total and the
    # summary counts it instead. --tokens is what its assistant events used.
    cost=$(flag cost "0" "$@"); duration_ms=$(flag duration-ms "0" "$@"); turns=$(flag turns "0" "$@")
    slug=$(flag slug "" "$@"); role=$(flag role "" "$@"); attempt=$(flag attempt "0" "$@")
    session_id=$(flag session-id "" "$@"); context_tokens=$(flag context-tokens "0" "$@"); head=$(flag head "" "$@")
    cost_unknown=false; unknown_note=""; tokens=$(flag tokens "0" "$@")
    for a in "$@"; do
      if [ "$a" = "--cost-unknown" ]; then cost_unknown=true; cost=0; unknown_note=" cost_unknown=true tokens=$tokens"; fi
    done
    edit_state --argjson c "$cost" --argjson d "$duration_ms" --argjson t "$turns" \
      --argjson unknown "$cost_unknown" --argjson tokens "$tokens" \
      --arg slug "$slug" --arg role "$role" --argjson attempt "$attempt" \
      --arg sid "$session_id" --argjson ctx "$context_tokens" --arg head "$head" '
      .total_cost_usd = ((.total_cost_usd // 0) + $c)
      | .total_dispatch_duration_ms = ((.total_dispatch_duration_ms // 0) + $d)
      | .total_dispatch_turns = ((.total_dispatch_turns // 0) + $t)
      | if $slug != "" and $role != "" then
          .dispatches = ((.dispatches // []) + [{
            run: (.current_run // null), slug: $slug, role: $role, attempt: $attempt,
            cost_usd: $c, duration_ms: $d, turns: $t,
            cost_unknown: $unknown, tokens: (if $unknown then $tokens else null end),
            session_id: (if $sid == "" then null else $sid end),
            context_tokens: $ctx, head: (if $head == "" then null else $head end)
          }])
        else . end'
    trace --level debug STATE "dispatch-cost${slug:+ slug=$slug}${role:+ role=$role}${slug:+ attempt=$attempt} cost=$cost duration_ms=$duration_ms turns=$turns$unknown_note"
    echo "STATE: dispatch-cost${slug:+ slug=$slug}${role:+ role=$role}${slug:+ attempt=$attempt} cost=$cost duration_ms=$duration_ms turns=$turns$unknown_note"
    ;;

  run-start)
    # Marks the start of one crew-afk invocation: every dispatch-cost entry after this is
    # tagged with it. The feature-wide totals keep accumulating across runs.
    #
    # It also counts the run (`runs`, across invocations) and keeps why the one before ended
    # (`previous_exit`, for the summary): a `current_run` that wrote no matching `last_exit`
    # (run-end) was killed or crashed before its own exit path ran.
    run_id=$(flag id "" "$@")
    [ -n "$run_id" ] || die "run-start requires --id"
    unended=$(jq -r 'if .current_run != null and (.last_exit.run // null) != .current_run then "yes" else "" end' "$SF")
    edit_state --arg r "$run_id" --arg unended "$unended" '
      .previous_exit = (if $unended != "" then {run: .current_run, reason: "ended without an exit (killed or crashed)"}
                        elif .current_run != null then .last_exit else null end)
      | .runs = ((.runs // 0) + 1)
      | .current_run = $r'
    if [ -n "$unended" ]; then
      trace --level warn STATE "previous run ended without an exit (killed or crashed)"
      echo "STATE: previous run ended without an exit (killed or crashed)"
    fi
    trace STATE "run-start id=$run_id"
    echo "STATE: run-start id=$run_id"
    ;;

  run-end)
    # Why this run ended, written by every orchestrator exit path (main.mjs). The next
    # run-start reads it back: a run that never wrote one was killed or crashed.
    reason=$(flag reason "" "$@"); code=$(flag code "" "$@")
    if [ -z "$reason" ] || ! [[ "$code" =~ ^[0-9]+$ ]]; then
      die "usage: state.sh run-end --reason <text> --code <n>"
    fi
    edit_state --arg reason "$reason" --argjson code "$code" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.last_exit = {run: (.current_run // null), reason: $reason, code: $code, at: $at}'
    trace --level "$([ "$code" = 0 ] && echo info || echo warn)" STATE "run-end code=$code reason=$reason"
    echo "STATE: run-end code=$code reason=$reason"
    ;;

  baseline)
    # The feature branch's own checks, run once before any dispatch (preflight.mjs), and again
    # on the merged branch at each drain (`--slot integration`). Only a pass is ever reused, and
    # only for the same commit; each slot caches on its own.
    commit=$(flag commit "" "$@"); verdict=$(flag verdict "" "$@"); slot=$(flag slot baseline "$@")
    tree=$(flag tree "" "$@")
    [ -n "$commit" ] || die "baseline requires --commit"
    case "$verdict" in pass|fail) : ;; *) die "baseline requires --verdict pass|fail" ;; esac
    case "$slot" in baseline|integration) : ;; *) die "baseline requires --slot baseline|integration" ;; esac
    # A passing tree is also added to the run-independent `passing_trees` set: the same tree needs no second check.
    edit_state --arg k "$slot" --arg c "$commit" --arg v "$verdict" --arg t "$tree" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.[$k] = ({commit: $c, verdict: $v, at: $at} + (if $t == "" then {} else {tree: $t} end))
       | if $v == "pass" and $t != "" then .passing_trees = (((.passing_trees // []) + [$t]) | unique) else . end'
    trace --level "$([ "$verdict" = pass ] && echo info || echo error)" STATE "$slot commit=$commit verdict=$verdict"
    echo "STATE: $slot commit=$commit verdict=$verdict"
    ;;

  verified-tree)
    # A per-issue verify passed this git tree: runFeatureChecks reuses it for a feature branch of the same tree.
    tree=$(flag tree "" "$@")
    [ -n "$tree" ] || die "verified-tree requires --tree"
    edit_state --arg t "$tree" '.passing_trees = (((.passing_trees // []) + [$t]) | unique)'
    trace STATE "verified-tree tree=$tree"
    echo "STATE: verified-tree tree=$tree"
    ;;

  feature-reviewed)
    # The feature branch tip a feature review that wrote a report covered: the next run reviews
    # only what came after it. Survives runs, like passing_trees.
    tip=$(flag tip "" "$@")
    [ -n "$tip" ] || die "feature-reviewed requires --tip"
    edit_state --arg t "$tip" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.feature_review = ((.feature_review // {}) + {reviewed_tip: $t, at: $at})'
    trace STATE "feature-reviewed tip=$tip"
    echo "STATE: feature-reviewed tip=$tip"
    ;;

  feature-review-promoted)
    # A feature review created the feature's fix issue. The promotion cap (loop.mjs) counts these per
    # feature, so it survives runs like reviewed_tip; a state file without it counts as 0.
    edit_state '.feature_review = ((.feature_review // {}) | .promotions = ((.promotions // 0) + 1))'
    n=$(jq -r '.feature_review.promotions' "$SF")
    trace STATE "feature-review-promoted promotions=$n"
    echo "STATE: feature-review-promoted promotions=$n"
    ;;

  resume)
    # Does this issue have a branch from an earlier round that still exists?
    # Both halves are mechanical — a recorded branch name and a ref lookup — and both
    # used to sit in the prompt as a jq call plus `git branch --list`. A worker told to
    # resume on a branch that no longer exists starts over and silently loses the WIP.
    slug=$(flag slug "" "$@")
    [ -n "$slug" ] || die "resume requires --slug"
    prior=$(jq -r --arg s "$slug" '.retained_branches[$s] // empty' "$SF")
    if [ -n "$prior" ] && [ -n "$(git -C "$MAIN_ROOT" branch --list "$prior")" ]; then
      echo "resume: $prior"
    else
      echo "no prior branch"
    fi
    ;;

  retention)
    # A retained branch's *reason* is what tells the orchestrator whether the branch's
    # content needs another worker pass or only another review attempt — resume answers
    # "is there a branch", this answers "why was it retained". Read from `.retention`,
    # never inferred from `.retained_branches` alone: a blocked issue is retained too, but
    # with a "blocked — ..." reason that must never be mistaken for a review-only retry.
    slug=$(flag slug "" "$@")
    [ -n "$slug" ] || die "retention requires --slug"
    reason=$(jq -r --arg s "$slug" '.retention[$s].reason // empty' "$SF")
    if [ -n "$reason" ]; then
      echo "reason: $reason"
      fp=$(jq -r --arg s "$slug" '.retention[$s].fingerprint // empty' "$SF")
      [ -z "$fp" ] || echo "fingerprint: $fp"
    else
      echo "no retention record"
    fi
    ;;

  get)
    field="${1:?state.sh get <field>}"
    case "$field" in
      merged) csv '(.merged_branches // [])' ;;
      retained) csv '((.retained_branches // {}) | [.[]] | unique)' ;;
      completed) csv '(.completed_slugs // [])' ;;
      partial) csv '((.retention // {}) | [to_entries[] | select(.value.reason | startswith("blocked") | not) | .key])' ;;
      blocked) csv '(.blocked_slugs // [])' ;;
      model) jq -r '.model // "sonnet"' "$SF" ;;
      round) jq -r '.round // 1' "$SF" ;;
      rounds) jq -r '.rounds // .round // 1' "$SF" ;;
      total-cost-usd) jq -r '.total_cost_usd // 0' "$SF" ;;
      total-dispatch-duration-ms) jq -r '.total_dispatch_duration_ms // 0' "$SF" ;;
      total-dispatch-turns) jq -r '.total_dispatch_turns // 0' "$SF" ;;
      feature-slug) jq -r '.feature_slug // empty' "$SF" ;;
      feature-review-promotions) jq -r '.feature_review.promotions // 0' "$SF" ;;
      runs) jq -r '.runs // 1' "$SF" ;;
      previous-exit) jq -r '.previous_exit.reason // "none"' "$SF" ;;
      state-file) printf '%s\n' "$SF" ;;
      *) die "unknown field: $field" ;;
    esac
    ;;

  show) cat "$SF" ;;

  *) usage ;;
esac
