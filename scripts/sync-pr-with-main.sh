#!/usr/bin/env bash
set -uo pipefail

# sync-pr-with-main.sh — merge origin/main into a PR branch and repair registry.json versions (D4).
#
# Usage: scripts/sync-pr-with-main.sh <branch>
#
# Fetches origin, checks out <branch>, merges origin/main (no fast-forward). Conflicts confined to
# registry.json entry `version`s and CHANGELOG.md appends are resolved by
# skills/crew-afk/scripts/resolve-merge-conflicts.sh; any other conflict leaves the merge in
# progress (nothing committed) and exits 1. Then every agents.*/skills.* entry this branch changed
# (measured from the merge-base) whose version is not strictly above origin/main's is bumped to one
# above it — at the level the branch itself bumped (major/minor), else patch. The merge commit is
# created with the repaired registry.json. Nothing is pushed; no remote is written to.

REMOTE=origin
MAIN="$REMOTE/main"
die() { echo "sync-pr-with-main: $*" >&2; exit 1; }

BRANCH="${1:-}"
[ -n "$BRANCH" ] || die "usage: $0 <branch>"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a git repository"
command -v node >/dev/null 2>&1 || die "node is required"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOP=$(git rev-parse --show-toplevel)
cd "$TOP" || exit 1

git fetch "$REMOTE" || die "git fetch $REMOTE failed"
git rev-parse --verify -q "$MAIN^{commit}" >/dev/null || die "$MAIN not found after fetch"
git checkout "$BRANCH" || die "cannot check out $BRANCH"

BRANCH_TIP=$(git rev-parse HEAD)
BASE=$(git merge-base HEAD "$MAIN") || die "no merge-base between $BRANCH and $MAIN"

if ! git merge --no-ff --no-commit "$MAIN"; then
  CONFLICTS=$(git diff --name-only --diff-filter=U)
  RESOLVER=""
  for r in "$SCRIPT_DIR/../skills/crew-afk/scripts/resolve-merge-conflicts.sh" \
           "$TOP/skills/crew-afk/scripts/resolve-merge-conflicts.sh"; do
    [ -f "$r" ] && { RESOLVER="$r"; break; }
  done
  if [ -z "$CONFLICTS" ] || [ -z "$RESOLVER" ] || ! bash "$RESOLVER"; then
    echo "sync-pr-with-main: merge of $MAIN into $BRANCH has conflicts that need a human:" >&2
    if [ -n "$CONFLICTS" ]; then printf '  %s\n' $CONFLICTS >&2; else echo "  (merge failed without conflicts; see git output above)" >&2; fi
    echo "The merge is left in progress; resolve, commit, or 'git merge --abort'." >&2
    exit 1
  fi
fi

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "$BRANCH already contains $MAIN; nothing to do."
  exit 0
fi

TMP=$(mktemp -d "$(git rev-parse --git-dir)/sync-pr.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
git show "$BASE:registry.json" >"$TMP/base.json" 2>/dev/null || die "registry.json missing at merge-base"
git show "$BRANCH_TIP:registry.json" >"$TMP/branch.json" 2>/dev/null || die "registry.json missing on $BRANCH"
git show "$MAIN:registry.json" >"$TMP/main.json" 2>/dev/null || die "registry.json missing on $MAIN"
git diff --name-only "$BASE" "$BRANCH_TIP" >"$TMP/changed.txt"

node - "$TMP" <<'JS' || die "version repair failed; merge left in progress"
const fs = require('fs');
const dir = process.argv[2];
const rd = (n) => fs.readFileSync(`${dir}/${n}`, 'utf8');
const base = JSON.parse(rd('base.json')), branch = JSON.parse(rd('branch.json')), main = JSON.parse(rd('main.json'));
const changed = rd('changed.txt').split('\n').filter(Boolean);
const curText = fs.readFileSync('registry.json', 'utf8');
const cur = JSON.parse(curText);
const fmt = (o) => JSON.stringify(o, null, 2) + '\n';
if (fmt(cur) !== curText) { console.error('registry.json is not canonically formatted; cannot rewrite it'); process.exit(1); }

const parse = (v) => { const m = /^(\d+)\.(\d+)\.(\d+)/.exec(String(v)); return m ? m.slice(1).map(Number) : null; };
const cmp = (a, b) => { for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] - b[i]; return 0; };
const bump = (v, level) => level === 'major' ? [v[0] + 1, 0, 0] : level === 'minor' ? [v[0], v[1] + 1, 0] : [v[0], v[1], v[2] + 1];
const noVer = (e) => { const c = { ...(e || {}) }; delete c.version; return JSON.stringify(c); };

function shipped(section, name, e) {
  const p = [];
  if (e['source-dir']) p.push(`${section === 'skills' ? 'skills' : 'agents'}/${e['source-dir']}`);
  const as = e.assets && e.assets.source;
  if (as) p.push(as);
  if (section === 'skills') {
    for (const s of e.scripts || []) p.push(`scripts/skill-utils/git-workflow/${s}`);
  }
  return p;
}

let dirty = false;
for (const section of ['agents', 'skills']) {
  for (const [name, e] of Object.entries(cur[section] || {})) {
    const mv = main[section] && main[section][name] && main[section][name].version;
    const mp = mv && parse(mv);
    if (!mp) continue;                       // absent on main
    const b = base[section] && base[section][name];
    const br = branch[section] && branch[section][name];
    if (!br) continue;
    const touched = noVer(b) !== noVer(br) || (b && b.version !== br.version) ||
      shipped(section, name, br).some((p) => changed.some((c) => c === p || c.startsWith(p + '/')));
    if (!touched) continue;
    const cv = parse(e.version);
    if (cv && cmp(cv, mp) > 0) continue;     // already above main
    const bp = b && parse(b.version), brp = parse(br.version);
    const level = bp && brp && brp[0] > bp[0] ? 'major' : bp && brp && brp[1] > bp[1] ? 'minor' : 'patch';
    const next = bump(mp, level).join('.');
    console.log(`registry.json: ${section}.${name} version ${e.version} -> ${next} (above origin/main's ${mv}, ${level} bump)`);
    e.version = next; dirty = true;
  }
}
if (dirty) fs.writeFileSync('registry.json', fmt(cur));
JS

git add registry.json || die "git add failed"
git commit -q -m "Merge $MAIN into $BRANCH" || die "commit failed; merge left in progress"
echo "Merged $MAIN into $BRANCH at $(git rev-parse --short HEAD). Not pushed."
