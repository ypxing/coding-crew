#!/usr/bin/env bash
set -uo pipefail

# resolve-merge-conflicts.sh — finish a conflicted `git merge` when its only conflicts are the
# two kinds parallel issue branches always produce on one shared skill:
#
#   - registry.json: the `version` of an agents.*/skills.* entry both sides bumped. The higher
#     semver wins, per entry. Every other field is merged by git as usual; any conflict there,
#     or any other conflicted line, leaves the merge unresolved.
#   - CHANGELOG.md: entries both sides appended at the same place. Both are kept, the side being
#     merged INTO (the feature branch) first. A conflict that changes existing lines is not one.
#
# Usage: resolve-merge-conflicts.sh [--head-is-branch]   (run inside the repo, mid-merge)
#
# By default HEAD is the feature branch and the branch being merged in is the issue branch
# (merge-branches.sh). With --head-is-branch the merge runs the other way — the feature branch
# is merged INTO an issue branch's worktree (a sync) — so "ours" is the issue branch: the
# decision labels and the CHANGELOG order (feature entries first) follow the sides, not the stages.
#
# All-or-nothing: if any unmerged path is not resolvable, nothing is written or staged and the
# exit code is 1, so the caller aborts the merge exactly as it would have without this script.
# On success every resolved file is staged (the caller commits) and one line per decision is
# printed:
#   registry.json: skills.crew-afk version 2.6.1 (feature) vs 2.7.0 (branch) -> 2.7.0
#   CHANGELOG.md: kept 1 entry from the feature side and 2 from the branch side
#
# Exit code: 0 resolved and staged; 1 not resolvable (or nothing is unmerged).

HEAD_IS_BRANCH=0
case "${1:-}" in
  --head-is-branch) HEAD_IS_BRANCH=1; shift ;;
  "") ;;
  *) echo "usage: resolve-merge-conflicts.sh [--head-is-branch]" >&2; exit 2 ;;
esac

cd "$(git rev-parse --show-toplevel)" || exit 1
UNMERGED=$(git diff --name-only --diff-filter=U 2>/dev/null)
[ -n "$UNMERGED" ] || exit 1
while IFS= read -r f; do
  case "$f" in registry.json|CHANGELOG.md) ;; *) exit 1 ;; esac
done <<<"$UNMERGED"
command -v node >/dev/null 2>&1 || exit 1

TMP=$(mktemp -d "$(git rev-parse --git-dir)/crew-resolve.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

while IFS= read -r f; do
  for stage in 1 2 3; do
    git show ":$stage:$f" >"$TMP/$f.$stage" 2>/dev/null || exit 1   # no base (add/add) → not ours to resolve
  done
done <<<"$UNMERGED"

HEAD_IS_BRANCH=$HEAD_IS_BRANCH node - "$TMP" $UNMERGED <<'JS' || exit 1
const fs = require('fs');
const { spawnSync } = require('child_process');
const [dir, ...files] = process.argv.slice(2);
const read = (f, n) => fs.readFileSync(`${dir}/${f}.${n}`, 'utf8');
const fail = () => process.exit(1);
const swap = process.env.HEAD_IS_BRANCH === '1';   // stage 2 (ours) is the issue branch, stage 3 the feature

// git merge-file <ours> <base> <theirs>, to stdout; status = number of conflicts (<0 on error).
function mergeFile(f, ours, base, theirs, diff3) {
  for (const [n, t] of [[2, ours], [1, base], [3, theirs]]) fs.writeFileSync(`${dir}/${f}.m${n}`, t);
  const r = spawnSync('git', ['merge-file', '-p', ...(diff3 ? ['--diff3'] : []),
    '-L', swap ? 'branch' : 'feature', '-L', 'base', '-L', swap ? 'feature' : 'branch', `${dir}/${f}.m2`, `${dir}/${f}.m1`, `${dir}/${f}.m3`],
    { encoding: 'utf8' });
  return { conflicts: r.status, text: r.stdout };
}

const semver = (v) => {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/.exec(String(v));
  return m ? { n: [+m[1], +m[2], +m[3]], pre: m[4] } : null;
};
function higher(a, b) {
  const x = semver(a), y = semver(b);
  if (!x || !y) fail();
  for (let i = 0; i < 3; i++) if (x.n[i] !== y.n[i]) return x.n[i] > y.n[i] ? a : b;
  if (x.pre === y.pre) return a;
  if (x.pre === undefined) return a;
  if (y.pre === undefined) return b;
  return x.pre >= y.pre ? a : b;
}

const entries = (o) => {
  const out = [];
  for (const [s, sec] of Object.entries(o))
    if (sec && typeof sec === 'object' && !Array.isArray(sec))
      for (const [n, e] of Object.entries(sec))
        if (e && typeof e === 'object' && typeof e.version === 'string') out.push([s, n, e]);
  return out;
};

const out = {};
const log = [];

function registry(f) {
  const parse = (n) => { try { return JSON.parse(read(f, n)); } catch { return fail(); } };
  const [base, ours, theirs] = [1, 2, 3].map(parse);
  const fmt = (o) => JSON.stringify(o, null, 2) + '\n';
  // Only a file this script would write back byte-for-byte is safe to normalise through JSON.
  for (const n of [1, 2, 3]) if (fmt(parse(n)) !== read(f, n)) fail();
  const blank = (o) => { const c = JSON.parse(JSON.stringify(o)); for (const [, , e] of entries(c)) e.version = ''; return fmt(c); };
  const m = mergeFile(f, blank(ours), blank(base), blank(theirs), false);
  if (m.conflicts !== 0) fail();   // a real conflict elsewhere in registry.json
  const merged = JSON.parse(m.text);
  const find = (o, s, n) => o[s] && o[s][n] && typeof o[s][n].version === 'string' ? o[s][n].version : undefined;
  for (const [s, n, e] of entries(merged)) {
    const a = find(ours, s, n), b = find(theirs, s, n), c = find(base, s, n);
    const pick = a !== undefined && b !== undefined ? higher(a, b) : (a ?? b ?? c);
    if (pick === undefined) fail();
    if (a !== undefined && b !== undefined && a !== b)
      log.push(`registry.json: ${s}.${n} version ${swap ? b : a} (feature) vs ${swap ? a : b} (branch) -> ${pick}`);
    e.version = pick;
  }
  out[f] = fmt(merged);
}

function changelog(f) {
  const m = mergeFile(f, read(f, 2), read(f, 1), read(f, 3), true);
  if (m.conflicts < 0) fail();
  const lines = m.text.split('\n');
  const res = [];
  let feat = 0, br = 0;
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
    feat += entryCount(swap ? c : a); br += entryCount(swap ? a : c);
    res.push(...(swap ? [...c, ...a] : [...a, ...c]));   // feature side first
  }
  if (m.conflicts > 0) log.push(`CHANGELOG.md: kept ${feat} entr${feat === 1 ? 'y' : 'ies'} from the feature side and ${br} from the branch side`);
  out[f] = res.join('\n');
}

for (const f of files) (f === 'registry.json' ? registry : changelog)(f);
for (const [f, text] of Object.entries(out)) fs.writeFileSync(f, text);
console.log(log.join('\n'));
JS
RC=$?
[ "$RC" -eq 0 ] || exit 1
while IFS= read -r f; do git add -- "$f" || exit 1; done <<<"$UNMERGED"
exit 0
