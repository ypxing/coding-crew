#!/usr/bin/env bash
# lint-issues.sh — read-only checker for a feature's issue set. Prints `ERROR <file>: <problem>` (breaks
# dispatch or the gates) or `WARN <file>: <problem>` (a judgement call); exit 0 no ERROR, 1 some, 2 usage.
# Usage: bash lint-issues.sh --issue <file> [--issue <file> …] [--known <file> …] [--deps <issues-deps.json>] [--prd <file>]
# --known: an issue outside the set a `## Blocked by` ref may resolve to by basename; never linted, but its
# `## Implements` counts toward PRD coverage (lines starting `- **D<n>**` / `- **B<n>**`, bar `(no slice)`).
# Issue files are data: only read by grep/awk/read, never evaluated; Blocked by refs are never opened.

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

# section <file> <heading> — body of a `## <heading>` section (### included) up to the next `## `,
# ignoring headings in code fences. Empty when absent; has_section tells absent from empty.
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

# strip_markup <token> — sets STRIPPED to the token minus leading/trailing markup (`**x.md**.` -> x.md), without a subshell.
strip_markup() {
  STRIPPED="$1"
  local prev=""
  while [[ "$STRIPPED" != "$prev" ]]; do
    prev="$STRIPPED"
    STRIPPED="${STRIPPED#[\`\*\(\[<\"\']}"
    STRIPPED="${STRIPPED%[\`\*\)\]>\"\',;:.]}"
  done
}

resolve_number() {
  local n="$1" name
  for name in "${NAMES[@]}" "${KNOWN[@]+"${KNOWN[@]}"}"; do
    if [[ "$name" =~ ^0*${n}[-_.] ]]; then printf '%s' "$name"; return 0; fi
  done
  return 1
}

PROSE_EDGES=()    # by index in NAMES: newline-separated resolved blocker filenames
BLOCKED_ON="|"    # |name|name|… — issues another issue blocks on
EDGE_LIST=""

for idx in "${!NAMES[@]}"; do
  name="${NAMES[$idx]}"
  file="${PATHS[$idx]}"

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
    # A person ticks each criterion as they finish it, so publish them unticked.
    section "$file" "Acceptance criteria" | awk '
      /^[ \t]*```/ { fence = !fence; next }
      !fence && /^[ \t]*[-*][ \t]+\[[xX]\]/ { sub(/^[ \t]+/, ""); print }' |
      while IFS= read -r ticked; do
        warn "$file" "ready-for-human acceptance criterion is ticked — leave criteria unticked when publishing: $ticked"
      done
  else
    has_section "$file" "What to build" || warn "$file" "no ## What to build section"
    has_section "$file" "Implements" || warn "$file" "no ## Implements section"
  fi

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
    # Issue refs (`Issue #n`, bare `#n`), read without *.md tokens so fix-issue-3-thing.md is not one.
    read -r -a toks <<< "$entry"
    rest=""
    for tok in "${toks[@]+"${toks[@]}"}"; do
      strip_markup "$tok"
      [[ "$STRIPPED" == *.md ]] || rest+="$tok "
    done
    # A pull-request mention (`PR`, `pull` or `pull request` before a #number) is prose, not a ref.
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
    # Filename refs: *.md tokens minus markup. A path or markdown link resolves by its basename only,
    # never opened. Any other token is prose; an entry with no ref at all is reported below.
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

for idx in "${!NAMES[@]}"; do
  [[ "$BLOCKED_ON" == *"|${NAMES[$idx]}|"* ]] || continue
  if ! section "${PATHS[$idx]}" "Interfaces" | grep -q -E '^###[[:space:]]+Exposes'; then
    warn "${PATHS[$idx]}" "another issue blocks on this one but it has no ### Exposes: under ## Interfaces"
  fi
done

if [[ -n "$DEPS_FILE" ]]; then
  for idx in "${!NAMES[@]}"; do
    name="${NAMES[$idx]}"
    json_list=$(jq -r --arg k "$name" '(.[$k] // []) | map(tostring) | unique | .[]' "$DEPS_FILE" 2>/dev/null | sort -u | sed '/^$/d')
    # An edge to a --known issue lives only in ## Blocked by (publish refuses it in deps.json), yet a
    # resumed sprint's deps.json may list one: compare drafts only, so neither side errors.
    prose_list=""
    while IFS= read -r blocker; do
      [[ -n "$blocker" ]] && in_set "$blocker" && prose_list+="${prose_list:+$'\n'}$blocker"
    done <<< "${PROSE_EDGES[$idx]}"
    drafts_json=""
    while IFS= read -r blocker; do
      [[ -z "$blocker" ]] && continue
      if in_set "$blocker" || ! is_ref "$blocker"; then
        drafts_json+="${drafts_json:+$'\n'}$blocker"
      fi
    done <<< "$json_list"
    json_list="$drafts_json"
    if [[ "$json_list" != "$prose_list" ]]; then
      jl=$(printf '%s' "$json_list" | paste -sd, - | sed 's/,/, /g')
      pl=$(printf '%s' "$prose_list" | paste -sd, - | sed 's/,/, /g')
      err "${PATHS[$idx]}" "--deps edges differ from ## Blocked by: deps=[${jl}] prose=[${pl}]"
    fi
    while IFS= read -r blocker; do
      [[ -n "$blocker" ]] && in_set "$blocker" && EDGE_LIST+="$name $blocker"$'\n'
    done <<< "$json_list"
  done
fi

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
      if grep -q -x -F -e "${NAMES[$i]} ${NAMES[$j]}" -e "${NAMES[$j]} ${NAMES[$i]}" <<<"$REACH"; then
        continue
      fi
      warn "${PATHS[$i]}" "names the same file as ${PATHS[$j]} with no ## Blocked by between them: $shared (advisory: add a Blocked by only if to-issues' edge rule row 1 or 2 matches)"
    done
  done
fi

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
      if ! grep -q -E "(^|[^A-Za-z0-9])${id}([^0-9]|\$)" <<<"$implemented"; then
        warn "$PRD_FILE" "$id is not named by any issue's ## Implements"
      fi
    done <<< "$ids"
  fi
fi

((ERRORS == 0)) || exit 1
exit 0
