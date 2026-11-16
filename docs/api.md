# books.js API

## getBook(id)

Returns the book with the given id: `{ id, title, price }`, `price` in dollars.
Throws `unknown book: <id>` when no book has that id.

## priceOf(id)

Returns the book's price in cents. Throws `unknown book: <id>` when no book has that id, as `getBook` does.
