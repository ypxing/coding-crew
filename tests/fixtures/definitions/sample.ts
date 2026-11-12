import { readFile } from "node:fs/promises";

export interface Draft {
  title: string;
}

export type Ref = string | number;

export enum Kind {
  Local,
  Github,
}

const DEFAULT_LIMIT = 10;

export abstract class Tracker {
  abstract fetch(ref: Ref): Promise<string>;
}

export default class LocalTracker extends Tracker {
  #root: string;

  constructor(root: string) {
    super();
    this.#root = root;
  }

  async fetch(ref: Ref): Promise<string> {
    return readFile(`${this.#root}/${ref}`, "utf8");
  }

  static fromEnv(): LocalTracker {
    return new LocalTracker(process.env.ROOT ?? ".");
  }

  private create(draft: Draft) {
    if (draft.title) {
      return draft;
    }
    return null;
  }

  *pages(limit = DEFAULT_LIMIT) {
    yield limit;
  }
}

export async function* walk(dir: string) {
  yield dir;
}

export function parse<T>(text: string): T {
  return JSON.parse(text) as T;
}

export const helpers = {
  create(draft: Draft) {
    return draft;
  },
  async list() {
    return [];
  },
};
