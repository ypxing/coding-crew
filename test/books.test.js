const test = require("node:test");
const assert = require("node:assert");
const { getBook, priceOf, priceOfFormatted } = require("../books.js");

test("getBook returns the book with that id", () => {
  assert.strictEqual(getBook("b2").title, "Rivers of the North");
});

test("getBook throws for an unknown id", () => {
  assert.throws(() => getBook("nope"), /unknown book: nope/);
});

test("priceOf returns the price in cents", () => {
  assert.strictEqual(priceOf("b1"), 1299);
  assert.strictEqual(priceOf("b3"), 800);
});

test("priceOf throws for an unknown id, as getBook does", () => {
  assert.throws(() => priceOf("nope"), /unknown book: nope/);
});

test("priceOfFormatted returns the price as a display string", () => {
  assert.strictEqual(priceOfFormatted("b2"), "$24.50");
});

test("priceOfFormatted throws for an unknown id", () => {
  assert.throws(() => priceOfFormatted("nope"), /unknown book: nope/);
});
