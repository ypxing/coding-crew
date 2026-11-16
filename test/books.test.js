const test = require("node:test");
const assert = require("node:assert");
const { getBook } = require("../books.js");

test("getBook returns the book with that id", () => {
  assert.strictEqual(getBook("b2").title, "Rivers of the North");
});

test("getBook throws for an unknown id", () => {
  assert.throws(() => getBook("nope"), /unknown book: nope/);
});
