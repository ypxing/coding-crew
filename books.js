// The shop's catalogue. Prices are in dollars, as the supplier lists them.
const BOOKS = [
  { id: "b1", title: "The Pragmatic Gardener", price: 12.99 },
  { id: "b2", title: "Rivers of the North", price: 24.5 },
  { id: "b3", title: "A Short History of Maps", price: 8 },
];

function getBook(id) {
  const book = BOOKS.find((b) => b.id === id);
  if (!book) throw new Error(`unknown book: ${id}`);
  return book;
}

function priceOf(id) {
  return Math.round(getBook(id).price * 100);
}

function priceOfFormatted(id) {
  return `$${getBook(id).price.toFixed(2)}`;
}

module.exports = { getBook, priceOf, priceOfFormatted };
