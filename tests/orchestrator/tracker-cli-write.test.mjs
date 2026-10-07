import { test } from "node:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { run } from "../../tracker/cli.mjs";

// tracker/cli.mjs — the write ops (`publish-issues`, `publish-prd`, `rewrite`, `mark-done`) on
// both backends, `gh` stubbed through the injected `exec`, as tracker-cli.test.mjs does for the
// read ops. mark-issue-done.sh's own contract is pinned by the bats suites.

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../..");

function root({ github = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "crew-tracker-cli-write-"));
  mkdirSync(join(dir, ".scratch"), { recursive: true });
  if (github) {
    mkdirSync(join(dir, ".coding-crew/docs"), { recursive: true });
    writeFileSync(join(dir, ".coding-crew/docs/issue-tracker.md"), "---\ntracker: github\n---\n");
  }
  return dir;
}

async function cli(mainRoot, argv, exec = () => assert.fail("gh must not be called"), env = {}) {
  let stdout = "";
  let stderr = "";
  const code = await run([...argv, "--main-root", mainRoot], {
    exec,
    cwd: mainRoot,
    env,
    out: (s) => (stdout += s),
    err: (s) => (stderr += s),
  });
  return { code, stdout, stderr };
}

/**
 * A fake `gh`: `routes` maps an argv prefix to a result, or to a function of the argv returning
 * one; every call is recorded, with a `--body-file`'s content captured as it was at call time.
 */
function fakeGh(routes) {
  const calls = [];
  const bodies = [];
  const exec = (cmd, args) => {
    calls.push([cmd, ...args]);
    const bf = args.indexOf("--body-file");
    bodies.push(bf === -1 ? null : readFileSync(args[bf + 1], "utf8"));
    const key = Object.keys(routes).find((k) => args.join(" ").startsWith(k));
    if (!key) return { code: 1, stdout: "", stderr: `unexpected gh ${args.join(" ")}` };
    const r = typeof routes[key] === "function" ? routes[key](args) : routes[key];
    return { code: r.code ?? 0, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  };
  exec.calls = calls;
  exec.bodies = bodies;
  exec.find = (prefix) => calls.map((c, i) => [c, i]).filter(([c]) => c.slice(1).join(" ").startsWith(prefix));
  return exec;
}

/** `gh issue create` numbering issues from `first` up, in call order. */
function creates(first) {
  let n = first;
  return () => ({ stdout: `https://github.com/o/n/issues/${n++}\n` });
}

const DRAFT_A = "# Add a\n\nStatus: ready-for-agent\n\n## What to build\n\nA.\n\n## Acceptance criteria\n\n- [ ] a works\n";
const DRAFT_B =
  "# Add b\n\nStatus: ready-for-human\n\n## What to build\n\nB.\n\n## Acceptance criteria\n\n- [ ] b works\n\n## Blocked by\n\n- 01-a.md\n";

function drafts(dir, { deps = { "02-b.md": ["01-a.md"] }, files = { "01-a.md": DRAFT_A, "02-b.md": DRAFT_B } } = {}) {
  const d = join(dir, ".scratch/feat/.drafts");
  mkdirSync(d, { recursive: true });
  for (const [name, text] of Object.entries(files)) writeFileSync(join(d, name), text);
  if (deps !== null) writeFileSync(join(d, "deps.json"), JSON.stringify(deps));
  return d;
}

// --- publish-issues (github) --------------------------------------------------------

test("publish-issues (github) creates blockers first and rewrites the dependent's Blocked by to the real number", async () => {
  const dir = root({ github: true });
  const d = drafts(dir);
  const exec = fakeGh({
    "api repos/{owner}/{repo}/milestones?state=all": { stdout: "1\topen\tfeat\n" },
    "issue create": creates(11),
    "api repos/{owner}/{repo}/issues/11": { stdout: "9011\n" },
    "api -X POST": {},
  });
  const r = await cli(dir, ["publish-issues", "--feature-slug", "feat", "--drafts", d], exec);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.stdout, "01-a.md 11\n02-b.md 12\n");

  const made = exec.find("issue create");
  assert.equal(made.length, 2);
  const [[a, ai], [b, bi]] = made;
  const flag = (call, name) => call[call.indexOf(name) + 1];
  assert.equal(flag(a, "--title"), "Add a");
  assert.equal(flag(a, "--label"), "ready-for-agent");
  assert.equal(flag(a, "--milestone"), "feat");
  assert.equal(flag(b, "--title"), "Add b");
  assert.equal(flag(b, "--label"), "ready-for-human");
  assert.equal(flag(b, "--milestone"), "feat");
  assert.doesNotMatch(exec.bodies[ai], /^# Add a|^Status:/m);
  assert.match(exec.bodies[ai], /^## What to build/);
  assert.doesNotMatch(exec.bodies[bi], /^# Add b|^Status:/m);
  assert.match(exec.bodies[bi], /## Blocked by\n\n- Issue #11\n/);
  assert.doesNotMatch(exec.bodies[bi], /01-a\.md/);
  // 02-b's blocker is linked natively once it exists.
  assert.equal(exec.find("api -X POST repos/{owner}/{repo}/issues/12/dependencies/blocked_by").length, 1);
});
