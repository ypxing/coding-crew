import { test } from "node:test";
import assert from "node:assert/strict";
import { readOnlyDispatch } from "../../orchestrator/lib/pipeline/shared.mjs";

function ctxWith(statusSeq) {
  const effects = { mutations: 0 };
  let status = 0;
  effects.gitRead = (args) => {
    if (args[0] === "status") return { code: 0, stdout: statusSeq[Math.min(status++, statusSeq.length - 1)], stderr: "" };
    return { code: 0, stdout: "abc\n", stderr: "" };
  };
  const logs = [];
  return { ctx: { sprint: { featureSlug: "demo", featureBranch: "f" }, effects, log: (m) => logs.push(m) }, effects, logs };
}

test("a main-checkout edit is a violation even when another worker's effect ran meanwhile", async () => {
  const { ctx, effects, logs } = ctxWith(["", " M file.txt\n"]);
  const r = await readOnlyDispatch(ctx, { label: "triage alpha", branches: ["crew/demo/alpha"] }, async () => {
    effects.mutations += 2;
  });
  assert.match(r.violation ?? "", /uncommitted changes in the main checkout/);
  assert.match(logs.join("\n"), /\[READONLY-VIOLATION\] triage alpha/);
});

test("no change under a concurrent effect is not a violation", async () => {
  const { ctx, effects } = ctxWith([""]);
  const r = await readOnlyDispatch(ctx, { label: "triage alpha", branches: ["crew/demo/alpha"] }, async () => {
    effects.mutations += 2;
    return "ok";
  });
  assert.equal(r.result, "ok");
});
