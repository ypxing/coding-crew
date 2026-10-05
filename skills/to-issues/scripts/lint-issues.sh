#!/usr/bin/env bash
# lint-issues.sh — read-only checker for a feature's issue set.
#
# Usage:
#   bash lint-issues.sh --issue <file> [--issue <file> …] [--known <file> …] [--deps <issues-deps.json>] [--prd <file>]
#
# --known names an issue outside the set being linted (already done, or published by an earlier
# run) that a `## Blocked by` ref may resolve to, by basename. It is never linted; when the file
# exists, its `## Implements` counts toward the PRD coverage check.
#
# Prints one line per problem:
#   ERROR <file>: <problem>   breaks dispatch or the gates
#   WARN  <file>: <problem>   a judgement call
# Exit 0 = no ERROR (warnings allowed), 1 = at least one ERROR, 2 = usage error (unknown flag,
# no --issue, unreadable file).
#
# ERROR: a dependency cycle; a `## Blocked by` ref (filename, or `Issue #<n>`) matching no issue in
#        the set; --deps edges that differ from the `## Blocked by` prose; no `## Acceptance criteria`.
# WARN:  more than 10 acceptance criteria (a context-budget check — does it fit one coder session?
#        never a rule to split); a **D<n>**/**B<n>** ID in --prd that no issue's (nor --known
#        file's) `## Implements` names, unless its PRD line ends in `(no slice)`; an issue another issue blocks on with no `### Exposes:` under
#        `## Interfaces`; no `## What to build`; no `## Implements`. A `Status: ready-for-human`
#        issue instead gets: no `## For a human` section, or that section missing one of its five
#        `###` parts (Why a person, What changes, Steps, If skipped or done wrong, Done when); it is
#        exempt from the `## What to build` / `## Implements` warnings. Two issues that name the
#        same file (a path with a `/`, `:<line>` dropped) with neither reaching the other through
#        `## Blocked by` (directly or via other issues in the set): parallel coders may conflict on it.
#        One WARN per pair, on the first file. Paths under `## Blocked by` / `## Context Documents`,
#        under `.scratch/`, and in URLs do not count; --known issues are never read.
#
# The PRD ID contract: a line starting `- **D<n>**` or `- **B<n>**`. A line ending in `(no slice)`
# marks a decision no issue needs to implement (already true, or only constrains other slices).
# Without --prd (or with a PRD that has no such IDs) the coverage check is skipped silently.
#
# Issue files are data. Their text is only ever read by grep/awk/read — never evaluated — and a
# `## Blocked by` entry is only compared, by basename, with the --issue/--known files, never opened.

set -uo pipefail
set -f # no globbing of anything read from an issue file

ISSUES=()
KNOWN=()
KNOWN_PATHS=()
DEPS_FILE=""
PRD_FILE=""

usage() {
  echo "usage: lint-issues.sh --issue <file> [--issue <file> …] [--known <file> …] [--deps <issues-deps.json>] [--prd <file>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) [[ $# -ge 2 ]] || usage; ISSUES+=("$2"); shift 2 ;;
    --known) [[ $# -ge 2 ]] || usage; KNOWN+=("${2##*/}"); KNOWN_PATHS+=("$2"); shift 2 ;;
    --deps) [[ $# -ge 2 ]] || usage; DEPS_FILE="$2"; shift 2 ;;
    --prd) [[ $# -ge 2 ]] || usage; PRD_FILE="$2"; shift 2 ;;
    *) echo "lint-issues.sh: unknown argument: $1" >&2; usage ;;
  esac
done

[[ ${#ISSUES[@]} -gt 0 ]] || usage
for f in "${ISSUES[@]}"; do
  [[ -f "$f" && -r "$f" ]] || { echo "lint-issues.sh: unreadable issue file: $f" >&2; exit 2; }
done
if [[ -n "$PRD_FILE" ]]; then
  [[ -f "$PRD_FILE" && -r "$PRD_FILE" ]] || { echo "lint-issues.sh: unreadable PRD: $PRD_FILE" >&2; exit 2; }
fi
if [[ -n "$DEPS_FILE" ]]; then
  [[ -f "$DEPS_FILE" && -r "$DEPS_FILE" ]] || { echo "lint-issues.sh: unreadable deps file: $DEPS_FILE" >&2; exit 2; }
  jq -e 'type == "object" and all(.[]; type == "array")' "$DEPS_FILE" >/dev/null 2>&1 \
    || { echo "lint-issues.sh: deps file is not a filename → [filenames] JSON map: $DEPS_FILE" >&2; exit 2; }
fi

ERRORS=0
err() { printf 'ERROR %s: %s\n' "$1" "$2"; ERRORS=$((ERRORS + 1)); }
warn() { printf 'WARN %s: %s\n' "$1" "$2"; }

# section <file> <heading> — body of a `## <heading>` section (### subsections included), up to the
# next `## ` heading. Headings inside code fences are ignored. Empty when the section is absent;
# use has_section to tell absent from empty.
section() {
  SECTION_NAME="$2" awk '
    BEGIN { want = tolower(ENVIRON["SECTION_NAME"]); on = 0 }
    /^[ \t]*```/ { fence = !fence }
    !fence && /^##[ \t]+/ && !/^###/ {
      h = $0; sub(/^##[ \t]+/, "", h); sub(/[ \t:]+$/, "", h)
      on = (tolower(h) == want); next
    }
    on { print }
  ' "$1"
}

has_section() {
  SECTION_NAME="$2" awk '
    BEGIN { want = tolower(ENVIRON["SECTION_NAME"]); found = 0 }
    /^[ \t]*```/ { fence = !fence }
    !fence && /^##[ \t]+/ && !/^###/ {
      h = $0; sub(/^##[ \t]+/, "", h); sub(/[ \t:]+$/, "", h)
      if (tolower(h) == want) found = 1
    }
    END { exit !found }
  ' "$1"
}

# --- the set: basename -> path ---
in_set() {
  local n
  for n in "${NAMES[@]+"${NAMES[@]}"}"; do [[ "$n" == "$1" ]] && return 0; done
  return 1
}
path_of() {
  local i
  for i in "${!NAMES[@]}"; do
    if [[ "${NAMES[$i]}" == "$1" ]]; then printf '%s' "${PATHS[$i]}"; return 0; fi
  done
  return 1
}
# Parallel arrays rather than associative ones: macOS ships bash 3.2.
NAMES=()
PATHS=()
for f in "${ISSUES[@]}"; do
  b="${f##*/}"
  in_set "$b" && continue
  NAMES+=("$b")
  PATHS+=("$f")
done

# is_ref <name> — a filename a `## Blocked by` ref may resolve to: in the set, or --known.
is_ref() {
  local n
  in_set "$1" && return 0
  for n in "${KNOWN[@]+"${KNOWN[@]}"}"; do [[ "$n" == "$1" ]] && return 0; done
  return 1
}

# strip_markup <token> — sets STRIPPED to the token minus every leading/trailing markup or
# punctuation character (`**x.md**.` -> x.md). Pure parameter expansion: no subshell, no globbing.
strip_markup() {
  STRIPPED="$1"
  local prev=""
  while [[ "$STRIPPED" != "$prev" ]]; do
    prev="$STRIPPED"
    STRIPPED="${STRIPPED#[\`\*\(\[<\"\']}"
    STRIPPED="${STRIPPED%[\`\*\)\]>\"\',;:.]}"
  done
}

# Resolve `Issue #n` to the set member whose filename starts with the number.
resolve_number() {
  local n="$1" name
  for name in "${NAMES[@]}" "${KNOWN[@]+"${KNOWN[@]}"}"; do
    if [[ "$name" =~ ^0*${n}[-_.] ]]; then printf '%s' "$name"; return 0; fi
  done
  return 1
}

# --- per-issue checks + prose edges ---
PROSE_EDGES=()    # by index in NAMES: newline-separated resolved blocker filenames
BLOCKED_ON="|"    # |name|name|… — issues another issue blocks on
EDGE_LIST=""

for idx in "${!NAMES[@]}"; do
  name="${NAMES[$idx]}"
  file="${PATHS[$idx]}"

  # Acceptance criteria
  if has_section "$file" "Acceptance criteria"; then
    count=$(section "$file" "Acceptance criteria" | grep -c -E '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' || true)
    if ((count > 10)); then
      warn "$file" "$count acceptance criteria (over 10: a context-budget check — does it fit one coder session?)"
    fi
  else
    err "$file" "no ## Acceptance criteria section"
  fi

  if grep -q -E '^[Ss]tatus:[[:space:]]*ready-for-human[[:space:]]*$' "$file"; then
    if has_section "$file" "For a human"; then
      for part in "Why a person" "What changes" "Steps" "If skipped or done wrong" "Done when"; do
        section "$file" "For a human" | PART="$part" awk '
          /^[ \t]*```/ { fence = !fence }
          !fence && /^###[ \t]+/ { h = $0; sub(/^###[ \t]+/, "", h); sub(/[ \t:]+$/, "", h); if (tolower(h) == tolower(ENVIRON["PART"])) found = 1 }
          END { exit !found }' || warn "$file" "## For a human has no ### $part"
      done
    else
      warn "$file" "ready-for-human issue has no ## For a human section"
    fi
  else
    has_section "$file" "What to build" || warn "$file" "no ## What to build section"
    has_section "$file" "Implements" || warn "$file" "no ## Implements section"
  fi

  # Blocked by
  resolved=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" ]] && continue
    entry="${trimmed#[-*] }"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    # "None", "_None_", "**None** - can start", "—": no ref. Markup and dashes stripped first.
    lower=$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')
    lower="${lower//[_\*\`~]/}"
    lower="${lower#"${lower%%[![:space:]]*}"}"
    [[ -z "${lower//[[:space:]—–-]/}" ]] && continue
    case "$lower" in none* | n/a* | nothing*) continue ;; esac

    found=0
    # `Issue #n` / `Issue n` / bare `#n` references (the set github.mjs's blockerNumbers reads) — scanned over the entry minus its *.md filename tokens, so a
    # filename like fix-issue-3-thing.md is not also read as "Issue #3"
    read -r -a toks <<< "$entry"
    rest=""
    for tok in "${toks[@]+"${toks[@]}"}"; do
      strip_markup "$tok"
      [[ "$STRIPPED" == *.md ]] || rest+="$tok "
    done
    # A `PR #n` / `pull #n` / `pull request #n` mention is prose, not a ref (github.mjs strips the same).
    rest=$(printf '%s' "$rest" | sed -E 's/(^|[^[:alnum:]])([Pp][Rr]|[Pp][Uu][Ll][Ll]([[:space:]]+[Rr][Ee][Qq][Uu][Ee][Ss][Tt])?)[[:space:]]*#[0-9]+/\1/g')
    while [[ "$rest" =~ ([Ii][Ss][Ss][Uu][Ee][[:space:]-]*#?|#)0*([0-9]+) ]]; do
      found=1
      n="${BASH_REMATCH[2]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      if target=$(resolve_number "$n"); then
        resolved+="$target"$'\n'
      else
        err "$file" "## Blocked by ref matches no issue in the set: Issue #$n"
      fi
    done
    # Filename references: whitespace-separated *.md tokens, stripped of markup. A path or a
    # markdown link (`[01-x.md](../open/01-x.md)`) resolves by its basename only — never opened.
    # Any other token is prose (`schema/API`); an entry with no ref at all is reported below.
    for tok in "${toks[@]+"${toks[@]}"}"; do
      strip_markup "$tok"
      tok="$STRIPPED"
      [[ "$tok" == *.md ]] || continue
      found=1
      base="${tok##*/}"
      if [[ "$base" == *.md && "$base" != *'$'* && "$base" != *'`'* ]] && is_ref "$base"; then
        resolved+="$base"$'\n'
      else
        err "$file" "## Blocked by ref matches no issue in the set: $tok"
      fi
    done
    if ((found == 0)); then
      err "$file" "## Blocked by ref matches no issue in the set: $entry"
    fi
  done < <(section "$file" "Blocked by")

  resolved=$(printf '%s' "$resolved" | sort -u | sed '/^$/d')
  PROSE_EDGES[$idx]="$resolved"
  while IFS= read -r blocker; do
    [[ -z "$blocker" ]] && continue
    BLOCKED_ON+="$blocker|"
    EDGE_LIST+="$name $blocker"$'\n'
  done <<< "$resolved"
done

# --- Exposes on anything another issue blocks on ---
for idx in "${!NAMES[@]}"; do
  [[ "$BLOCKED_ON" == *"|${NAMES[$idx]}|"* ]] || continue
  if ! section "${PATHS[$idx]}" "Interfaces" | grep -q -E '^###[[:space:]]+Exposes'; then
    warn "${PATHS[$idx]}" "another issue blocks on this one but it has no ### Exposes: under ## Interfaces"
  fi
done

# --- --deps JSON vs prose ---
if [[ -n "$DEPS_FILE" ]]; then
  for idx in "${!NAMES[@]}"; do
    name="${NAMES[$idx]}"
    json_list=$(jq -r --arg k "$name" '(.[$k] // []) | map(tostring) | unique | .[]' "$DEPS_FILE" 2>/dev/null | sort -u | sed '/^$/d')
    prose_list="${PROSE_EDGES[$idx]}"
    if [[ "$json_list" != "$prose_list" ]]; then
      jl=$(printf '%s' "$json_list" | paste -sd, - | sed 's/,/, /g')
      pl=$(printf '%s' "$prose_list" | paste -sd, - | sed 's/,/, /g')
      err "${PATHS[$idx]}" "--deps edges differ from ## Blocked by: deps=[${jl}] prose=[${pl}]"
    fi
    # JSON edges join the graph for cycle detection
    while IFS= read -r blocker; do
      [[ -n "$blocker" ]] && in_set "$blocker" && EDGE_LIST+="$name $blocker"$'\n'
    done <<< "$json_list"
  done
fi

# --- cycles: DFS over "issue blocker" edges ---
if [[ -n "$EDGE_LIST" ]]; then
  while IFS= read -r cyc; do
    [[ -z "$cyc" ]] && continue
    first="${cyc%% *}"
    err "$(path_of "$first" || printf '%s' "$first")" "dependency cycle: ${cyc// / -> }"
  done < <(printf '%s' "$EDGE_LIST" | sort -u | awk '
    { adj[$1] = adj[$1] " " $2; nodes[$1] = 1; nodes[$2] = 1 }
    function visit(n,   i, k, parts, m, start, cyc, key, j, sorted) {
      state[n] = 1; stack[++depth] = n
      m = split(adj[n], parts, " ")
      for (i = 1; i <= m; i++) {
        k = parts[i]
        if (state[k] == 1) {
          start = 0
          for (j = depth; j >= 1; j--) if (stack[j] == k) { start = j; break }
          cyc = ""
          for (j = start; j <= depth; j++) cyc = cyc (cyc == "" ? "" : " ") stack[j]
          cyc = cyc " " k
          key = cyc
          if (!(key in seen)) { seen[key] = 1; print cyc }
        } else if (state[k] == 0) visit(k)
      }
      state[n] = 2; depth--
    }
    END { for (n in nodes) if (state[n] == 0) visit(n) }
  ')
fi

# --- same file named by two issues with no Blocked by path between them ---
# paths_of <file> — sorted unique file paths the issue names: a token with a `/` whose last part has
# an extension. `src/a.ts:10` counts as src/a.ts; Blocked by / Context Documents, URLs and .scratch/ do not.
paths_of() {
  awk '
    /^[ \t]*```/ { fence = !fence }
    !fence && /^##[ \t]+/ && !/^###/ {
      h = tolower($0); sub(/^##[ \t]+/, "", h); sub(/[ \t:]+$/, "", h)
      skip = (h == "blocked by" || h == "context documents"); next
    }
    !skip { print }
  ' "$1" \
    | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*##g' \
    | grep -o -E '[A-Za-z0-9_.~-]+(/[A-Za-z0-9_.-]+)+' \
    | sed -E 's#^(\./)+##; s#\.+$##' \
    | grep -E '/[^/]*[^/.]\.[A-Za-z0-9]+$' \
    | grep -v -E '^\.scratch/' \
    | sort -u || true
}

if ((${#NAMES[@]} > 1)); then
  # "a b" for every b reachable from a over Blocked by / --deps edges.
  REACH=$(printf '%s' "$EDGE_LIST" | sort -u | awk '
    NF == 2 { adj[$1] = adj[$1] " " $2; nodes[$1] = 1 }
    END {
      for (a in nodes) {
        split("", seen); n = 0; q[++n] = a
        for (i = 1; i <= n; i++) {
          m = split(adj[q[i]], parts, " ")
          for (j = 1; j <= m; j++) if (!(parts[j] in seen)) { seen[parts[j]] = 1; q[++n] = parts[j]; print a, parts[j] }
        }
      }
    }')
  FILE_PATHS=()
  for idx in "${!NAMES[@]}"; do FILE_PATHS[$idx]=$(paths_of "${PATHS[$idx]}"); done
  for i in "${!NAMES[@]}"; do
    [[ -n "${FILE_PATHS[$i]}" ]] || continue
    for j in "${!NAMES[@]}"; do
      ((j > i)) || continue
      [[ -n "${FILE_PATHS[$j]}" ]] || continue
      shared=$(comm -12 <(printf '%s\n' "${FILE_PATHS[$i]}") <(printf '%s\n' "${FILE_PATHS[$j]}") | paste -sd, - | sed 's/,/, /g')
      [[ -n "$shared" ]] || continue
      if printf '%s\n' "$REACH" | grep -q -x -F -e "${NAMES[$i]} ${NAMES[$j]}" -e "${NAMES[$j]} ${NAMES[$i]}"; then
        continue
      fi
      warn "${PATHS[$i]}" "names the same file as ${PATHS[$j]} with no ## Blocked by between them: $shared (parallel coders may conflict)"
    done
  done
fi

# --- PRD coverage ---
if [[ -n "$PRD_FILE" ]]; then
  # A `(no slice)` line needs no issue; it never errors when one implements it anyway.
  ids=$(grep -E '^[[:space:]]*[-*][[:space:]]+\*\*[DB][0-9]+\*\*' "$PRD_FILE" \
    | grep -v -E '\(no slice\)[[:space:]]*$' \
    | grep -o -E '^[[:space:]]*[-*][[:space:]]+\*\*[DB][0-9]+\*\*' | grep -o -E '[DB][0-9]+' | sort -u || true)
  if [[ -n "$ids" ]]; then
    implemented=""
    for f in "${PATHS[@]}"; do
      implemented+="$(section "$f" "Implements")"$'\n'
    done
    for f in "${KNOWN_PATHS[@]+"${KNOWN_PATHS[@]}"}"; do
      [[ -f "$f" && -r "$f" ]] && implemented+="$(section "$f" "Implements")"$'\n'
    done
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      if ! printf '%s\n' "$implemented" | grep -q -E "(^|[^A-Za-z0-9])${id}([^0-9]|\$)"; then
        warn "$PRD_FILE" "$id is not named by any issue's ## Implements"
      fi
    done <<< "$ids"
  fi
fi

((ERRORS == 0)) || exit 1
exit 0
