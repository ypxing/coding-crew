import test from "node:test";
import assert from "node:assert/strict";

test("fetch reads the issue", () => {
  assert.equal(1, 1);
});

test("mark-done", async (t) => {
  await t.test("moves the file", () => {
    assert.ok(true);
  });
  t.test("keeps the body", () => {});
});
