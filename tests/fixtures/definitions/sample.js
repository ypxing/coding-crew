const path = require("node:path");

function resolve(root, name) {
  return path.join(root, name);
}

async function load(file) {
  return file;
}

class Store {
  constructor(root) {
    this.root = root;
  }

  get size() {
    return 0;
  }

  async save(item) {
    return item;
  }
}

let cache = null;
var legacy = true;

module.exports = { resolve, load, Store };
