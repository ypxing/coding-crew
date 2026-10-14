#!/usr/bin/env bash
set -uo pipefail

# resolve-merge-conflicts.sh — finish a conflicted merge whose only conflicts are CHANGELOG.md appends
# (both kept, the branch's entries first).
# Usage: resolve-merge-conflicts.sh   (mid-merge, HEAD the branch being brought up to date)
# All-or-nothing: if anything is unresolvable, nothing is written and it exits 1, so the caller aborts
# as it would without this. On success the file is staged (the caller commits) and the decision printed.

[ $# -eq 0 ] || { echo "usage: resolve-merge-conflicts.sh" >&2; exit 2; }

cd "$(git rev-parse --show-toplevel)" || exit 1
UNMERGED=$(git diff --name-only --diff-filter=U 2>/dev/null)
[ "$UNMERGED" = CHANGELOG.md ] || exit 1
command -v node >/dev/null 2>&1 || exit 1

TMP=$(mktemp -d "$(git rev-parse --git-dir)/crew-resolve.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

for stage in 1 2 3; do
  git show ":$stage:CHANGELOG.md" >"$TMP/CHANGELOG.md.$stage" 2>/dev/null || exit 1   # no base (add/add) → not ours to resolve
done

node - "$TMP" <<'JS' || exit 1
const fs = require('fs');
const { spawnSync } = require('child_process');
const dir = process.argv[2];
const f = 'CHANGELOG.md';
const read = (n) => fs.readFileSync(`${dir}/${f}.${n}`, 'utf8');
const fail = () => process.exit(1);

// git merge-file --diff3 <ours> <base> <theirs>, to stdout; status = number of conflicts (<0 on error).
for (const n of [1, 2, 3]) fs.writeFileSync(`${dir}/${f}.m${n}`, read(n));
const r = spawnSync('git', ['merge-file', '-p', '--diff3', '-L', 'branch', '-L', 'base', '-L', 'main',
  `${dir}/${f}.m2`, `${dir}/${f}.m1`, `${dir}/${f}.m3`], { encoding: 'utf8' });
if (r.status < 0 || r.status === null) fail();

const lines = r.stdout.split('\n');
const res = [];
let ours = 0, theirs = 0;
const entryCount = (ls) => ls.filter((l) => /^[-*] /.test(l)).length;
for (let i = 0; i < lines.length; i++) {
  if (!lines[i].startsWith('<<<<<<< ')) { res.push(lines[i]); continue; }
  const a = [], b = [], c = [];
  let cur = a;
  for (i++; i < lines.length && !lines[i].startsWith('>>>>>>> '); i++) {
    if (lines[i].startsWith('||||||| ')) cur = b;
    else if (lines[i] === '=======') cur = c;
    else cur.push(lines[i]);
  }
  if (i >= lines.length || b.length > 0) fail();   // changed existing lines: not an append
  ours += entryCount(a); theirs += entryCount(c);
  res.push(...a, ...c);   // the branch's entries first
}
fs.writeFileSync(f, res.join('\n'));
if (r.status > 0) console.log(`CHANGELOG.md: kept ${ours} entr${ours === 1 ? 'y' : 'ies'} from the branch and ${theirs} from main`);
JS
git add -- CHANGELOG.md || exit 1
exit 0
