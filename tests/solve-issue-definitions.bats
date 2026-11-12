#!/usr/bin/env bats

# solve-issue Step 3's definitions map, scripts/map-definitions.sh, run on the samples in
# tests/fixtures/definitions/: every definition and test line named below must come out with its
# line number. Extra lines are fine; the script prints a map, and a missed definition sends the coder
# back to reading the whole file.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SCRIPT="$REPO_ROOT/skills/solve-issue/scripts/map-definitions.sh"
SAMPLES="$REPO_ROOT/tests/fixtures/definitions"

# Runs the script on one sample and checks each given line's text comes out at its line number.
_maps() {
  local sample="$SAMPLES/$1" out text n
  shift
  out=$(bash "$SCRIPT" "$sample") || { echo "map-definitions.sh failed on $sample"; return 1; }
  for text in "$@"; do
    n=$(grep -nF -- "$text" "$sample" | cut -d: -f1)
    [ -n "$n" ] || { echo "sample has no line: $text"; return 1; }
    for n in $n; do
      grep -q "^$n:" <<<"$out" || { echo "missed line $n: $text"; echo "$out"; return 1; }
    done
  done
}

@test "definitions: the pattern is one grep -E using POSIX classes only" {
  [ -f "$SCRIPT" ]
  body=$(grep -v '^[[:space:]]*#' "$SCRIPT")
  [[ "$body" != *'\s'* && "$body" != *'\w'* && "$body" != *'\d'* && "$body" != *' -P'* ]]
  [ "$(grep -o "grep -nE" <<<"$body" | wc -l)" -eq 1 ]
}

@test "definitions: prints each file's line count before the map" {
  run bash "$SCRIPT" "$SAMPLES/sample.py"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^[[:space:]]*[0-9]+[[:space:]].*sample\.py$ ]]
}

@test "definitions: a file with no definitions is an empty map, exit 0" {
  echo '{"a": 1}' > "$BATS_TEST_TMPDIR/data.json"
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/data.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *data.json* ]]
}

@test "definitions: no file is a usage error" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *[Uu]sage* ]]
}

@test "definitions: a file that does not exist fails" {
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/missing.ts"
  [ "$status" -ne 0 ]
}

@test "definitions: TypeScript, with class and object methods" {
  _maps sample.ts 'export interface Draft' 'export type Ref' 'export enum Kind' 'const DEFAULT_LIMIT' \
    'export abstract class Tracker' 'export default class LocalTracker' 'constructor(root: string) {' \
    'async fetch(ref: Ref)' 'static fromEnv()' 'private create(draft: Draft) {' '*pages(limit' \
    'export async function* walk' 'export function parse<T>' 'export const helpers' \
    '  create(draft: Draft) {' 'async list() {'
}

@test "definitions: JavaScript" {
  _maps sample.js 'function resolve' 'async function load' 'class Store' 'constructor(root) {' \
    'get size() {' 'async save(item) {' 'let cache' 'var legacy'
}

@test "definitions: Python" {
  _maps sample.py 'class Tracker' 'def __init__' 'async def fetch' 'def parse' 'async def walk'
}

@test "definitions: Go" {
  _maps sample.go 'type Tracker struct' 'type Fetcher interface' 'func New' 'func (t *Tracker) Fetch'
}

@test "definitions: Rust, with impl<T>" {
  _maps sample.rs 'pub struct Tracker<T>' 'pub enum Kind' 'pub trait Fetch' 'fn fetch(&self, r: &str) -> String;' \
    'impl<T: fmt::Display>' 'fn fetch(&self, r: &str) -> String {' 'impl Kind' 'pub fn name' \
    'pub(crate) async fn load' 'mod tests' 'pub fn parse'
}

@test "definitions: Ruby" {
  _maps sample.rb 'module Crew' 'class Tracker' 'def initialize' 'def self.from_env' 'def fetch'
}

@test "definitions: shell" {
  _maps sample.sh 'usage() {' 'function fetch_issue' '_mark-done () {'
}

@test "definitions: bats" {
  _maps sample.bats 'setup() {' 'teardown() {' '@test "fetch' '@test "mark-done'
}

@test "definitions: node:test, with t.test" {
  _maps sample.node-test.mjs 'test("fetch reads' 'test("mark-done"' 'await t.test(' 't.test("keeps'
}

@test "definitions: describe/it, with .skip and .only" {
  _maps sample.spec.ts 'describe("Tracker"' 'it("fetches' 'it.only(' 'describe.skip(' 'test("closes'
}

@test "definitions: RSpec" {
  _maps sample_spec.rb 'RSpec.describe' 'describe "#fetch" do' 'it "reads' 'context "when' "it 'raises'"
}
