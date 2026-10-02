#!/usr/bin/env bats

# scripts/sync-pr-with-main.sh — merge origin/main into a PR branch, repair registry versions.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  W="$BATS_TEST_TMPDIR"
  git init -q --bare "$W/origin.git"
  git clone -q "$W/origin.git" "$W/work" 2>/dev/null
  cd "$W/work"
  git config user.email t@t; git config user.name t
  git checkout -q -b main
  mkdir -p scripts skills/crew-afk/scripts skills/a
  cp "$REPO_ROOT/scripts/sync-pr-with-main.sh" scripts/
  cp "$REPO_ROOT/skills/crew-afk/scripts/resolve-merge-conflicts.sh" skills/crew-afk/scripts/
  reg 2.6.0 > registry.json
  printf '# Changelog\n\n' > CHANGELOG.md
  echo one > skills/a/f.txt
  git add -A; git commit -q -m base
  git push -q origin main 2>/dev/null
  git checkout -q -b feat
}

reg() { printf '{\n  "skills": {\n    "a": {\n      "version": "%s",\n      "source-dir": "a",\n      "description": "d"\n    }\n  }\n}\n' "$1"; }
commit_main() { git checkout -q main; "$@"; git add -A; git commit -q -m m; git push -q origin main 2>/dev/null; git checkout -q feat; }
ver() { jq -r .skills.a.version registry.json; }
refs() { git -C "$W/origin.git" for-each-ref; }

@test "registry version + changelog append conflicts: 2.7.2, both parents, branch entry first, repair printed" {
  echo '- branch entry' >> CHANGELOG.md; reg 2.6.2 > registry.json; git commit -qam b
  commit_main bash -c "echo '- main entry' >> CHANGELOG.md; $(declare -f reg); reg 2.7.1 > registry.json"
  before=$(refs)
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.7.2"* ]]
  [ "$(git rev-list --parents -1 HEAD | wc -w)" -eq 3 ]
  [ "$(ver)" = "2.7.2" ]
  [ "$(grep -n 'branch entry' CHANGELOG.md | cut -d: -f1)" -lt "$(grep -n 'main entry' CHANGELOG.md | cut -d: -f1)" ]
  [ "$before" = "$(refs)" ]
}

@test "both sides bumped 2.6.0 -> 2.6.1 (clean merge): 2.6.2" {
  reg 2.6.1 > registry.json; echo x > skills/a/g.txt; git add -A; git commit -qm b
  commit_main bash -c "echo y > other.txt; $(declare -f reg); reg 2.6.1 > registry.json"
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -eq 0 ]
  [ "$(ver)" = "2.6.2" ]
}

@test "shipped file changed without bump while main bumped: 2.6.2" {
  echo changed > skills/a/f.txt; git commit -qam b
  commit_main bash -c "$(declare -f reg); reg 2.6.1 > registry.json"
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -eq 0 ]
  [ "$(ver)" = "2.6.2" ]
}

@test "branch bumped minor to 2.7.0 while main is at 2.7.0: 2.8.0" {
  reg 2.7.0 > registry.json; git commit -qam b
  commit_main bash -c "$(declare -f reg); reg 2.7.0 > registry.json"
  run bash scripts/sync-pr-with-main.sh feat
  [ "$status" -eq 0 ]
  [ "$(ver)" = "2.8.0" ]
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

@test "conflict in non-version registry field: non-zero, merge in progress" {
  sed -i 's/"d"/"branch"/' registry.json; git commit -qam b
  commit_main bash -c "sed -i 's/\"d\"/\"main\"/' registry.json"
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

@test "CLAUDE.md names the script" {
  grep -q 'scripts/sync-pr-with-main.sh <branch>' "$REPO_ROOT/CLAUDE.md"
}
