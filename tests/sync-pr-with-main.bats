#!/usr/bin/env bats

# scripts/sync-pr-with-main.sh — merge origin/main into a PR branch, resolving CHANGELOG.md append conflicts.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  W="$BATS_TEST_TMPDIR"
  git init -q --bare "$W/origin.git"
  git clone -q "$W/origin.git" "$W/work" 2>/dev/null
  cd "$W/work"
  git config user.email t@t; git config user.name t
  git checkout -q -b main
  mkdir -p scripts skills/a
  cp "$REPO_ROOT/scripts/sync-pr-with-main.sh" "$REPO_ROOT/scripts/resolve-merge-conflicts.sh" scripts/
  reg d > registry.json
  printf '# Changelog\n\n' > CHANGELOG.md
  echo one > skills/a/f.txt
  git add -A; git commit -q -m base
  git push -q origin main 2>/dev/null
  git checkout -q -b feat
}

reg() { printf '{\n  "skills": {\n    "a": {\n      "source-dir": "a",\n      "description": "%s"\n    }\n  }\n}\n' "$1"; }
commit_main() { git checkout -q main; "$@"; git add -A; git commit -q -m m; git push -q origin main 2>/dev/null; git checkout -q feat; }
refs() { git -C "$W/origin.git" for-each-ref; }

@test "a changelog append conflict: both entries kept, branch entry first, both parents, nothing pushed" {
  echo '- branch entry' >> CHANGELOG.md; echo b > skills/a/g.txt; git add -A; git commit -qm b
  commit_main bash -c "echo '- main entry' >> CHANGELOG.md"
  before=$(refs)
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHANGELOG.md: kept 1 entry from the branch and 1 from main"* ]]
  [ "$(git rev-list --parents -1 HEAD | wc -w)" -eq 3 ]
  [ "$(grep -n 'branch entry' CHANGELOG.md | cut -d: -f1)" -lt "$(grep -n 'main entry' CHANGELOG.md | cut -d: -f1)" ]
  [ -f skills/a/g.txt ]
  [ "$before" = "$(refs)" ]
}

@test "registry.json is merged as it is: no version is repaired or added" {
  echo changed > skills/a/f.txt; git commit -qam b
  commit_main bash -c "$(declare -f reg); reg main > registry.json"
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -eq 0 ]
  [ "$(git show HEAD:registry.json)" = "$(git show origin/main:registry.json)" ]
  ! grep -q '"version"' registry.json
  ! grep -qi 'version' "$REPO_ROOT/scripts/sync-pr-with-main.sh" "$REPO_ROOT/scripts/resolve-merge-conflicts.sh"
}

@test "conflict in another file: non-zero, names file, no commit, merge in progress" {
  echo b > skills/a/f.txt; git commit -qam b; tip=$(git rev-parse HEAD)
  commit_main bash -c "echo m > skills/a/f.txt"
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -ne 0 ]
  [[ "$output" == *"skills/a/f.txt"* ]]
  [ "$(git rev-parse HEAD)" = "$tip" ]
  git rev-parse -q --verify MERGE_HEAD
}

@test "a registry.json conflict needs a human: non-zero, merge in progress" {
  sed -i.bak 's/"d"/"branch"/' registry.json; git commit -qam b
  commit_main bash -c "sed -i.bak 's/\"d\"/\"main\"/' registry.json"
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -ne 0 ]
  [[ "$output" == *"registry.json"* ]]
  git rev-parse -q --verify MERGE_HEAD
}

@test "missing branch argument, or failed fetch: non-zero before checkout" {
  run bash scripts/sync-pr-with-main.sh
  [ "$status" -ne 0 ]
  git remote set-url origin "$W/nonexistent.git"
  run bash scripts/sync-pr-with-main.sh main
  [ "$status" -ne 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feat" ]
}

@test "script never pushes or calls gh" {
  ! grep -Eq 'git push|(^|[^a-z])gh ' "$REPO_ROOT/scripts/sync-pr-with-main.sh"
}
