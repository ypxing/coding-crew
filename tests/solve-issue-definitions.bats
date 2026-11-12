#!/usr/bin/env bats

# solve-issue Step 3's definitions command, taken from SKILL.md as written and run on the samples in
# tests/fixtures/definitions/: every definition and test line named below must come out with its
# line number. Extra lines are fine; the command is a map, and a missed definition sends the coder
# back to reading the whole file.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SKILL="$REPO_ROOT/skills/solve-issue/SKILL.md"
SAMPLES="$REPO_ROOT/tests/fixtures/definitions"

# The `wc -l <files>; grep -nE '…' <files>` line of Step 3's fenced block.
_definitions_command() {
  awk '/^### 3\./ {in3 = 1; next} /^### / {in3 = 0} in3 && /^wc -l <files>; grep -nE / {print; exit}' "$SKILL"
}

# Runs the command on one sample and checks each given line's text comes out at its line number.
_maps() {
  local sample="$SAMPLES/$1" cmd out text n
  shift
  cmd=$(_definitions_command)
  [ -n "$cmd" ] || { echo "no definitions command in SKILL.md's Step 3"; return 1; }
  out=$(bash -c "${cmd//<files>/\"$sample\"}")
  for text in "$@"; do
    n=$(grep -nF -- "$text" "$sample" | cut -d: -f1)
    [ -n "$n" ] || { echo "sample has no line: $text"; return 1; }
    for n in $n; do
      grep -q "^$n:" <<<"$out" || { echo "missed line $n: $text"; echo "$out"; return 1; }
    done
  done
}

@test "definitions: the pattern is one grep -E using POSIX classes only" {
  cmd=$(_definitions_command)
  [ -n "$cmd" ]
  [[ "$cmd" != *'\s'* && "$cmd" != *'\w'* && "$cmd" != *'\d'* && "$cmd" != *' -P'* ]]
  [ "$(grep -o "grep -nE" <<<"$cmd" | wc -l)" -eq 1 ]
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
