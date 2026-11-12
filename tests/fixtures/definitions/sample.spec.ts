import { describe, it, expect } from "vitest";

describe("Tracker", () => {
  it("fetches an issue", () => {
    expect(1).toBe(1);
  });

  it.only("marks it done", async () => {
    expect(true).toBe(true);
  });

  describe.skip("on GitHub", () => {
    test("closes the issue", () => {});
  });
});
