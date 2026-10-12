#!/usr/bin/env bash
# verify.sh — one read-only verifier run: render a prompt template, compose the system prompt, run `claude -p`.
# Usage: verify.sh --template <md> --report <json> --log <file> --system <role.md>... --fragments <dir>
#          --timeout <min> --budget <usd> --model <m> [--omit-line '<prefix>']... <k>=<v>...
# Each <k> in the template becomes <v>, pairs in order: the last goes in last, so a placeholder named
# inside its value stays literal. A line starting with an --omit-line prefix is dropped before that.
# The system prompt (<log>.system.md) is the --system files joined by a blank line, each whole-line
# {{FRAGMENT:<key>}} replaced by <fragments>/<key>.md. Prints nothing; exit 0 iff <report> exists
# afterwards, 2 on a usage error or a placeholder left in the system prompt (before any claude call).
set -euo pipefail
usage() { echo "verify.sh: $*" >&2; exit 2; }
TPL="" REPORT="" LOG="" FRAGS="" MIN="" USD="" MODEL="" SYS=() OMIT=() PAIRS=()
while [ $# -gt 0 ]; do
  case "$1" in -*) [ $# -ge 2 ] || usage "$1 needs a value" ;; esac
  case "$1" in
    --template) TPL="$2" ;; --report) REPORT="$2" ;; --log) LOG="$2" ;; --fragments) FRAGS="$2" ;;
    --timeout) MIN="$2" ;; --budget) USD="$2" ;; --model) MODEL="$2" ;;
    --system) SYS+=("$2") ;; --omit-line) OMIT+=("$2") ;;
    -*) usage "unknown flag: $1" ;;
    *=*) PAIRS+=("$1"); shift; continue ;;
    *) usage "not a <k>=<v> pair: $1" ;;
  esac; shift 2
done
for v in TPL REPORT LOG FRAGS MIN USD MODEL; do [ -n "${!v}" ] || usage "missing --$(tr A-Z a-z <<<"$v")"; done
[ "${#SYS[@]}" -gt 0 ] || usage "missing --system"
[ -f "$TPL" ] || usage "no template at $TPL"

SYSFILE="$LOG.system.md"
for i in "${!SYS[@]}"; do
  [ -f "${SYS[$i]}" ] || usage "no role file at ${SYS[$i]}"
  [ "$i" = 0 ] || echo
  awk -v d="$FRAGS" '
    /^[ \t]*\{\{FRAGMENT:[A-Za-z0-9_-]+\}\}[ \t]*$/ {
      k = $0; gsub(/^[ \t]*\{\{FRAGMENT:|\}\}[ \t]*$/, "", k); f = d "/" k ".md"
      if ((getline l < f) > 0) { print l; while ((getline l < f) > 0) print l; close(f); next }
    }
    { print }' "${SYS[$i]}"
done >"$SYSFILE"
left=$(grep -o '{{[^}]*}}' "$SYSFILE" | head -1 || true)
[ -z "$left" ] || usage "$left left unresolved in $SYSFILE (fragments: $FRAGS)"

shopt -u patsub_replacement 2>/dev/null || true # else `&` in a value reads as the matched placeholder
t=$(OMITS="$(printf '%s\n' ${OMIT[@]+"${OMIT[@]}"})" awk '
  BEGIN { n = split(ENVIRON["OMITS"], p, "\n") }
  { for (i = 1; i <= n; i++) if (p[i] != "" && index($0, p[i]) == 1) next; print }' "$TPL")
for kv in ${PAIRS[@]+"${PAIRS[@]}"}; do k=${kv%%=*}; t=${t//"$k"/${kv#*=}}; done

rm -f "$REPORT"
timeout "${MIN}m" claude -p "$t" --append-system-prompt-file "$SYSFILE" \
  --tools Bash Read ToolSearch --settings '{"disableClaudeAiConnectors":true,"disableBundledSkills":true}' \
  --output-format json --max-budget-usd "$USD" --model "$MODEL" --permission-mode bypassPermissions \
  </dev/null >"$LOG" 2>&1 || true
[ -f "$REPORT" ]
