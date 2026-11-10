#!/usr/bin/env bash
# publish-spec.sh --cli <cli.mjs> --main-root <dir> --drafts <dir> --slug <slug> --spec <file> — start --spec's
# feature: the spec file published as the one-issue local feature <slug>, rebuilt from the file on every run, as on a
# fresh runner. The one part of solve-feature that knows the local tracker's layout; solve-feature.sh's loop names
# no tracker. Exit 0 published; 1 a stop, its one-line reason on stdout (the tracker CLI's own errors reach stderr).
set -euo pipefail
CLI="" MAIN_ROOT="" DRAFTS="" SLUG="" SPEC=""
while [ $# -gt 0 ]; do case "$1" in
    --cli) CLI="$2" ;; --main-root) MAIN_ROOT="$2" ;; --drafts) DRAFTS="$2" ;; --slug) SLUG="$2" ;; --spec) SPEC="$2" ;;
    *) echo "publish-spec.sh: unknown argument: $1" >&2; exit 2 ;;
  esac; shift 2; done
stop() { echo "$*"; exit 1; }

kind=$(node "$CLI" config | sed -n 's/^tracker=//p') || stop "the tracker CLI's config failed (see above)"
[ "$kind" = local ] || stop "--spec runs on the local tracker, and this repo's is '$kind': set CREW_TRACKER=local for the run"
[ -f "$SPEC" ] || stop "no spec file $SPEC"
grep -qE '^#[[:blank:]]+[^[:blank:]]' "$SPEC" || stop "spec file $SPEC has no '# <title>' line"

# Only a feature directory carrying this script's marker is removed: one without it is someone's real feature.
dir="$MAIN_ROOT/.coding-crew/scratch/$SLUG" marker=.solve-feature-spec
if [ -e "$dir" ]; then
  [ -f "$dir/$marker" ] || stop "$dir exists and no start --spec made it: move it aside, or pick another --issue, then re-run"
  rm -rf "$dir" || stop "cannot remove $dir (see above)"
fi

# The draft is the file with a Status line under its title and without its Blocked by section: the local tracker reads
# blockers only from issues-deps.json, written empty, and publish-issues would refuse a name it does not know.
rm -rf "$DRAFTS" && mkdir -p "$DRAFTS" && echo '{}' >"$DRAFTS/deps.json" || stop "cannot write $DRAFTS (see above)"
awk '/^##?#?#?#?#?[ \t]+/ { skip = tolower($0) ~ /^#+[ \t]+blocked by[ \t]*$/ }
  skip { next }
  !t && /^#[ \t]+[^ \t]/ { print; print ""; print "Status: ready-for-agent"; t = 1; next }
  { print }' "$SPEC" >"$DRAFTS/01-$SLUG.md" || stop "cannot write $DRAFTS (see above)"
node "$CLI" publish-issues --feature-slug "$SLUG" --drafts "$DRAFTS" >/dev/null || stop "publishing $SPEC failed (see above)"
echo "$SPEC" >"$dir/$marker" || stop "cannot write $dir/$marker (see above)"
