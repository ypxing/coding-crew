#!/bin/bash
# Test script for crew-afk findings promotion (scripts/promote-findings.sh)
#
# Covers the invariants that make the two-phase sprint terminate and stay safe:
#   1. defer parks an issue that the ready-for-agent selection does NOT pick up (Phase 1 unaffected)
#   2. one fix issue per reviewed branch, numbered after the highest existing issue (open + done)
#   3. defer annotates the review report with a ## Promoted Findings marker
#   4. guard is the depth bound: a Source:-bearing issue is never promoted again
#   5. flush flips parked issues to ready-for-agent and is idempotent (second run = no-op)
#   6. flush on a sprint with nothing parked reports FLUSH: none rather than failing
#   7. remind counts only findings promotion did NOT cover, so the end-of-sprint reminder is honest
#   8. the promotion threshold is the explicit --severities list the caller passes
#   9. under the default (actionable), a promoted branch's Actionable findings are handled whatever
#      their severity; Debatable and Dismissed ones stay open, and remind leads with Debatable

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
PROMOTE="$SCRIPT_DIR/promote-findings.sh"
# remind reads reviews through review-rollup.mjs, which the lookup below the temp repo can't
# find: point it at this source tree's copy (an install sets its own).
export CREW_REVIEW_ROLLUP="${CREW_REVIEW_ROLLUP:-$SCRIPT_DIR/../../../orchestrator/review-rollup.mjs}"

# review <header> <SEVERITY>... — one branch's block in the aggregate report's format: its
# header, then the reviewer's json, which names the branch (what review-rollup.mjs parses).
review() {
    local header="$1"; shift
    local findings="" sev
    for sev in "$@"; do
        findings="$findings${findings:+,}{\"severity\":\"$sev\",\"location\":\"x:1\",\"criterion\":\"$sev finding\"}"
    done
    printf '## Branch: %s\n\n```json\n{"branch":"%s","verdict":"all-met","findings":[%s]}\n```\n\n' \
        "$header" "${header%% (*}" "$findings"
}

TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "        expected: $expected"
        echo "        actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "  PASS: $desc"; PASS=$((PASS + 1)) ;;
        *) echo "  FAIL: $desc"; echo "        expected to contain: $needle"; echo "        actual: $haystack"; FAIL=$((FAIL + 1)) ;;
    esac
}

# The loop's issue selection, verbatim from the local tracker's `list` operation.
ready_queue() {
    grep -rl "Status: ready-for-agent" .scratch/*/issues/open/*.md 2>/dev/null | sort | tr '\n' ' '
}

echo "Testing crew-afk findings promotion..."
echo

mkdir -p .scratch/feat/issues/open .scratch/feat/issues/done .scratch/feat/reviews
printf '# closed one\n\nStatus: done\n' > .scratch/feat/issues/done/07-old.md
printf '# a\n\nStatus: ready-for-agent\n' > .scratch/feat/issues/open/01-a.md
printf '# b\n\nStatus: ready-for-agent\n' > .scratch/feat/issues/open/02-b.md
REPORT=.scratch/feat/reviews/sprint-review-x.md
printf '# Sprint review\n\n## Branch: crew/01-a\n[CRITICAL] boom\n' > "$REPORT"
printf -- '- [ ] fix the CRITICAL null deref at src/a.ts:10\n' > crit-a.md
printf -- '- [ ] fix the CRITICAL race at src/b.ts:42\n' > crit-b.md

echo "Test 1: guard allows promotion for an ordinary issue, naming the threshold"
out=$(bash "$PROMOTE" guard --issue .scratch/feat/issues/open/01-a.md --severities CRITICAL)
check "guard reports eligible at the pinned threshold" "guard: eligible — threshold: CRITICAL" "$out"

echo
echo "Test 2: defer numbers after the highest issue across open/ and done/"
out=$(bash "$PROMOTE" defer --feature-slug feat --branch crew/01-a --slug a \
        --title "Fix review findings: a" --report "$REPORT" --criteria-file crit-a.md --severities CRITICAL)
check "issue numbered 08 (done/07 is the max)" \
      "defer: .scratch/feat/issues/open/08-fix-findings-a.md" "$out"

echo
echo "Test 3: parked issue is invisible to the ready-for-agent queue"
check "queue still holds only the two Phase 1 issues" \
      ".scratch/feat/issues/open/01-a.md .scratch/feat/issues/open/02-b.md " "$(ready_queue)"
check "parked status written" "Status: deferred-findings" \
      "$(grep '^Status:' .scratch/feat/issues/open/08-fix-findings-a.md)"

echo
echo "Test 4: defer annotates the review report"
check_contains "report gains Promoted Findings section" "## Promoted Findings" "$(cat "$REPORT")"
check_contains "marker keys branch + severities + issue path" \
      "- crew/01-a: CRITICAL → .scratch/feat/issues/open/08-fix-findings-a.md" "$(cat "$REPORT")"

echo
echo "Test 5: second branch gets its own fix issue, one section header only"
out=$(bash "$PROMOTE" defer --feature-slug feat --branch crew/02-b --slug b \
        --title "Fix review findings: b" --report "$REPORT" --criteria-file crit-b.md --severities CRITICAL)
check "second issue numbered 09" \
      "defer: .scratch/feat/issues/open/09-fix-findings-b.md" "$out"
check "Promoted Findings header written once" "1" "$(grep -c '^## Promoted Findings' "$REPORT")"
check "two markers present" "2" "$(grep -c '^- crew/' "$REPORT")"

echo
echo "Test 6: guard is the depth bound — a fix issue is never promoted again"
out=$(bash "$PROMOTE" guard --issue .scratch/feat/issues/open/08-fix-findings-a.md --severities CRITICAL)
check_contains "guard skips source-guarded issue" "guard: skip" "$out"

echo
echo "Test 7: flush promotes parked issues to Phase 2"
out=$(bash "$PROMOTE" flush --feature-slug feat)
check_contains "flush reports the count" "FLUSH: promoted=2" "$out"
check "both fix issues now selectable" \
      ".scratch/feat/issues/open/01-a.md .scratch/feat/issues/open/02-b.md .scratch/feat/issues/open/08-fix-findings-a.md .scratch/feat/issues/open/09-fix-findings-b.md " \
      "$(ready_queue)"
check "Source: line survives the flush (depth bound intact)" \
      "Source: $REPORT (crew/01-a)" \
      "$(grep '^Source:' .scratch/feat/issues/open/08-fix-findings-a.md)"

echo
echo "Test 8: flush is idempotent — reaching a second exit is a no-op"
out=$(bash "$PROMOTE" flush --feature-slug feat)
check "second flush promotes nothing" "FLUSH: none" "$out"

echo
echo "Test 9: sprint with nothing parked flushes cleanly"
mkdir -p .scratch/other/issues/open
out=$(bash "$PROMOTE" flush --feature-slug other)
check "empty sprint reports none" "FLUSH: none" "$out"

echo
echo "Test 10: defer refuses an empty criteria file (nothing to promote)"
: > empty.md
if bash "$PROMOTE" defer --feature-slug feat --branch crew/03-c --slug c \
     --title "t" --report "$REPORT" --criteria-file empty.md --severities CRITICAL >/dev/null 2>&1; then
    echo "  FAIL: defer accepted an empty criteria file"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: defer rejects an empty criteria file"
    PASS=$((PASS + 1))
fi

echo
echo "Test 11: remind counts only findings promotion did not cover"
mkdir -p .scratch/rem/issues/open .scratch/rem/reviews
REM=.scratch/rem/reviews/sprint-review-1.md
{
    echo "# Sprint review"
    echo
    review "crew/01-a (01-a)" CRITICAL HIGH MEDIUM LOW
    review "crew/02-b (02-b)" MEDIUM
} > "$REM"
printf -- '- [ ] fix it\n' > rem-crit.md
bash "$PROMOTE" defer --feature-slug rem --branch crew/01-a --slug a \
    --title "Fix review findings: a" --report "$REM" --criteria-file rem-crit.md --severities CRITICAL >/dev/null
out=$(bash "$PROMOTE" remind --feature-slug rem)
check_contains "promoted CRITICAL excluded; HIGH/MEDIUM/LOW counted for a human" \
      "FINDINGS: open=4 (HIGH=1, MEDIUM=2, LOW=1)" "$out"
check_contains "report path listed for the user" "report: $REM" "$out"
# Subtraction reads the marker written in the report, not the current threshold: the record on
# disk is what a later /crew-address-findings run trusts.

echo
echo "Test 12: a Phase 2 fix branch's own findings are counted (report-only, needs a human)"
review "crew/08-fix-findings-a (08-fix-findings-a)" CRITICAL > .scratch/rem/reviews/sprint-review-2.md
out=$(bash "$PROMOTE" remind --feature-slug rem)
check_contains "CRITICAL on a fix branch surfaces in the reminder" \
      "FINDINGS: open=5 (CRITICAL=1, HIGH=1, MEDIUM=2, LOW=1)" "$out"

echo
echo "Test 13: remind stays quiet when there is nothing to triage"
mkdir -p .scratch/quiet/reviews
check "empty reviews dir reports none" "FINDINGS: none" "$(bash "$PROMOTE" remind --feature-slug quiet)"
mkdir -p .scratch/noreviews/issues/open
check "missing reviews dir reports none" "FINDINGS: none" "$(bash "$PROMOTE" remind --feature-slug noreviews)"
FULLY=.scratch/quiet/reviews/sprint-review-1.md
review "crew/01-x (01-x)" CRITICAL > "$FULLY"
printf -- '- [ ] fix it\n' > quiet-crit.md
bash "$PROMOTE" defer --feature-slug quiet --branch crew/01-x --slug x \
    --title "Fix review findings: x" --report "$FULLY" --criteria-file quiet-crit.md --severities CRITICAL >/dev/null
check "fully-promoted report reports none" "FINDINGS: none" \
      "$(bash "$PROMOTE" remind --feature-slug quiet)"

echo
echo "Test 14: branch attribution is the json's, whether or not the header has a (slug) suffix"
mkdir -p .scratch/bare/reviews
BARE=.scratch/bare/reviews/sprint-review-1.md
review "crew/01-y" HIGH LOW > "$BARE"
printf -- '- [ ] fix it\n' > bare-crit.md
bash "$PROMOTE" defer --feature-slug bare --branch crew/01-y --slug y \
    --title "Fix review findings: y" --report "$BARE" --criteria-file bare-crit.md --severities HIGH >/dev/null
check_contains "bare header still matches its promotion marker" "FINDINGS: open=1 (LOW=1)" \
      "$(bash "$PROMOTE" remind --feature-slug bare)"

echo
echo "Test 15: defer-integration parks one source-guarded fix issue for a fixable red integration check"
mkdir -p .scratch/integ/issues/open .scratch/integ/issues/done
touch .scratch/integ/issues/done/03-old.md
INTEG_OUT=.scratch/integ/dispatch/_integration/verify.out
mkdir -p "$(dirname "$INTEG_OUT")"
echo "alpha and beta clash" > "$INTEG_OUT"
printf -- '- [ ] The project'"'"'s checks pass on the merged feature branch\n' > integ-crit.md
out=$(bash "$PROMOTE" defer-integration --feature-slug integ --report "$INTEG_OUT" --criteria-file integ-crit.md)
check "numbered after the highest existing issue (open + done)" \
      "defer-integration: .scratch/integ/issues/open/04-fix-integration-1.md" "$out"
f=.scratch/integ/issues/open/04-fix-integration-1.md
check_contains "parked, so Phase 1 never sees it" "Status: deferred-findings" "$(cat "$f")"
check_contains "Source: names the report and the integration kind" "Source: $INTEG_OUT (integration)" "$(cat "$f")"
check_contains "criteria carried verbatim" "- [ ] The project's checks pass on the merged feature branch" "$(cat "$f")"
check_contains "guard treats it as a fix issue: never promoted again" "skip — source-guarded" \
      "$(bash "$PROMOTE" guard --issue "$f" --severities CRITICAL)"
out=$(bash "$PROMOTE" defer-integration --feature-slug integ --report "$INTEG_OUT" --criteria-file integ-crit.md)
check "a second is refused while one is open" "defer-integration: skip — already queued: $f" "$out"
check_contains "flush sends it into Phase 2" "FLUSH: promoted=1" "$(bash "$PROMOTE" flush --feature-slug integ)"
check_contains "flushed to ready-for-agent" "Status: ready-for-agent" "$(cat "$f")"
mv "$f" .scratch/integ/issues/done/
out=$(bash "$PROMOTE" defer-integration --feature-slug integ --report "$INTEG_OUT" --criteria-file integ-crit.md --at abc123)
check_contains "the second names the tip it was raised at" "# Fix integration check: integ (at abc123)" "$(cat .scratch/integ/issues/open/05-fix-integration-2.md)"
check "once the first is closed a later red drain can park another with a slug of its own (the caller caps the run)" \
      "defer-integration: .scratch/integ/issues/open/05-fix-integration-2.md" "$out"
: > integ-empty.md
if bash "$PROMOTE" defer-integration --feature-slug integ --report "$INTEG_OUT" --criteria-file integ-empty.md >/dev/null 2>&1; then
    check "an empty criteria file is refused" "refused" "accepted"
else
    check "an empty criteria file is refused" "refused" "refused"
fi

echo
echo "Test 16: actionable (the default) — verdicts beside each finding; Actionable handled, Debatable leads"
mkdir -p .scratch/act/issues/open .scratch/act/reviews
ACT=.scratch/act/reviews/sprint-review-1.md
cat > "$ACT" <<'EOF'
## Branch: crew/01-a (01-a)

```json
{"branch":"crew/01-a","verdict":"all-met","findings":[
 {"severity":"HIGH","location":"src/api.ts:9","criterion":"Rename the exported helper","verdict":"debatable","rationale":"public contract change"},
 {"severity":"LOW","location":"src/a.ts:1","criterion":"Name the constant","verdict":"actionable","rationale":"one local line"},
 {"severity":"MEDIUM","location":"src/b.ts:2","criterion":"Extra guard","verdict":"dismiss","rationale":"already guarded"}]}
```
EOF
printf -- '- [ ] [LOW] Name the constant (src/a.ts:1)\n' > act-crit.md
printf '# a\n\nStatus: ready-for-agent\n' > .scratch/act/issues/open/01-a.md
check_contains "guard names it" "eligible — threshold: actionable" \
      "$(bash "$PROMOTE" guard --issue .scratch/act/issues/open/01-a.md --severities actionable)"
bash "$PROMOTE" defer --feature-slug act --branch crew/01-a --slug a \
    --title "Fix review findings: a" --report "$ACT" --criteria-file act-crit.md --severities actionable >/dev/null
check_contains "the marker names the verdict, not a severity" "- crew/01-a: actionable → " "$(cat "$ACT")"
out=$(bash "$PROMOTE" remind --feature-slug act)
check_contains "the promoted Actionable LOW is handled; the rest are open" "FINDINGS: open=1 (HIGH=1)" "$out"
check_contains "Debatable is listed with its rationale" \
      "debatable: crew/01-a [HIGH] src/api.ts:9 — Rename the exported helper — why: public contract change" "$out"
check_contains "Dismissed is counted apart" "DISMISSED: 1" "$out"
check_contains "Dismissed is listed collapsed" "dismissed: crew/01-a [MEDIUM] src/b.ts:2 — Extra guard — why: already guarded" "$out"
case "$out" in
    *DEBATABLE:*DISMISSED:*) check "Debatable leads Dismissed" yes yes ;;
    *) check "Debatable leads Dismissed" yes no ;;
esac

echo
echo "Results: $PASS passed, $FAIL failed"
cd /
rm -rf "$TEST_DIR"
[ "$FAIL" -eq 0 ]
