/**
 * platform-golden-dispatch.test.mjs — today's dispatch argv and stdin, frozen per platform × agent.
 *
 * Every platform's `buildDispatch()` output ({cmd, args, input, env}) for crew-coder,
 * crew-reviewer, crew-triage and a plain dispatch (no role), with fixed paths, prompt and model,
 * compared against tests/fixtures/platform-golden/dispatch/<platform>-<agent>.json. A refactor of
 * the adapters must leave these byte-identical; a deliberate change regenerates them with
 * `UPDATE_GOLDEN=1 node --test tests/orchestrator/platform-golden-dispatch.test.mjs`.
 *
 * The temp root is written as `<TMP>` and each rendered role protocol as
 * `<PROTOCOL <agent> sha256:…>`, so a fixture holds where the protocol goes, not its text, and
 * no machine-specific path. Codex asks git for the worktree's git dirs, so `cwd` is a real
 * linked worktree.
 *
 * Also checks orchestrator/platforms.json against install.sh's platform helper and skill-dirs.mjs.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = fileURLToPath(new URL("../..", import.meta.url));
const FIXTURES = fileURLToPath(new URL("../fixtures/platform-golden/dispatch/", import.meta.url));
const PLATFORMS_JSON = JSON.parse(readFileSync(join(REPO, "orchestrator/platforms.json"), "utf8"));
const PLATFORMS = Object.keys(PLATFORMS_JSON);
const AGENTS = ["crew-coder", "crew-reviewer", "crew-triage", "plain"];
const UPDATE = process.env.UPDATE_GOLDEN === "1";

// The live environment must not reach the snapshot: a sprint's git env would point codex's
// `git rev-parse` elsewhere, and the fake seam or sandbox override would change the argv.
for (const k of Object.keys(process.env)) if (k.startsWith("GIT_")) delete process.env[k];
delete process.env.CREW_FAKE_DISPATCH;
delete process.env.CREW_CODEX_SANDBOX;
// A config-dir override would put a real skill install's path into the rendered protocol.
for (const { configDirEnv } of Object.values(PLATFORMS_JSON)) delete process.env[configDirEnv];

const rawTmp = mkdtempSync(join(tmpdir(), "crew-golden-dispatch-"));
const TMP = realpathSync(rawTmp);
process.env.HOME = join(TMP, "home");
mkdirSync(process.env.HOME);

const { buildDispatch, renderRolePrompt } = await import("../../orchestrator/lib/dispatch.mjs");
const { skillDirCandidates } = await import("../../orchestrator/lib/skill-dirs.mjs");

function git(cwd, ...args) {
  const r = spawnSync("git", ["-c", "user.name=golden", "-c", "user.email=golden@example.invalid", ...args], { cwd, encoding: "utf8" });
  assert.equal(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
}

const mainRoot = join(TMP, "repo");
const cwd = join(mainRoot, ".scratch/worktrees/alpha");
mkdirSync(mainRoot);
git(mainRoot, "init", "-q", "-b", "main");
git(mainRoot, "commit", "-q", "--allow-empty", "-m", "init");
git(mainRoot, "worktree", "add", "-q", "-b", "crew/golden/alpha", cwd);
const dispatchDir = join(mainRoot, ".scratch/golden/dispatch");
mkdirSync(dispatchDir, { recursive: true });
const promptFile = join(dispatchDir, "alpha.prompt.md");
writeFileSync(promptFile, "Implement the alpha issue.\n");

/** `text` with every temp path and rendered protocol replaced by a stable placeholder. */
function normalize(text, protocol, agent) {
  let out = text;
  if (protocol) {
    const tag = `<PROTOCOL ${agent} sha256:${createHash("sha256").update(protocol).digest("hex").slice(0, 16)}>`;
    out = out.replaceAll(JSON.stringify(protocol).slice(1, -1), tag);
  }
  for (const p of [TMP, rawTmp]) out = out.replaceAll(p, "<TMP>");
  return out;
}

function snapshot(platform, agent) {
  const b = buildDispatch(platform, {
    agent,
    cwd,
    mainRoot,
    promptFile,
    outFile: join(dispatchDir, "alpha.report.md"),
    model: "golden-model",
    slug: "alpha",
    baseRef: "crew/golden",
    logFile: join(mainRoot, ".scratch/golden/trace.log"),
  });
  const protocol = agent === "plain" ? null : renderRolePrompt(agent, platform, { mainRoot });
  const json = JSON.stringify({ cmd: b.cmd, args: b.args, input: b.input ?? null, env: b.env }, null, 2);
  return `${normalize(json, protocol, agent)}\n`;
}

/** The lines only one side has, `-` expected / `+` actual: enough to see what moved. */
function lineDiff(expected, actual) {
  const e = expected.split("\n");
  const a = actual.split("\n");
  return [...e.filter((l) => !a.includes(l)).map((l) => `- ${l}`), ...a.filter((l) => !e.includes(l)).map((l) => `+ ${l}`)].join("\n");
}

for (const platform of PLATFORMS) {
  for (const agent of AGENTS) {
    test(`dispatch golden: ${platform} × ${agent}`, () => {
      const file = join(FIXTURES, `${platform}-${agent}.json`);
      const actual = snapshot(platform, agent);
      assert.doesNotMatch(actual, /crew-golden-dispatch-/, `${platform} × ${agent}: a temp path escaped normalization`);
      if (UPDATE) {
        mkdirSync(FIXTURES, { recursive: true });
        writeFileSync(file, actual);
        return;
      }
      assert.ok(existsSync(file), `dispatch golden missing for platform ${platform}, agent ${agent}: ${file} (run with UPDATE_GOLDEN=1)`);
      const expected = readFileSync(file, "utf8");
      if (actual !== expected) {
        assert.fail(`dispatch golden changed for platform ${platform}, agent ${agent} (UPDATE_GOLDEN=1 to accept):\n${lineDiff(expected, actual)}`);
      }
    });
  }
}

test("platforms.json has one entry per install.sh platform, each with exactly the four D1 fields", () => {
  // install.sh's PLATFORMS comes from the helper it sources, which reads platforms.json.
  const r = spawnSync("bash", ["-c", 'source "$SCRIPT_DIR/scripts/lib/platforms.sh" && printf "%s\\n" "${PLATFORMS[@]}"'],
    { env: { ...process.env, SCRIPT_DIR: REPO, REPO_ROOT: REPO }, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual([...PLATFORMS].sort(), r.stdout.trim().split(/\s+/).sort());
  for (const p of PLATFORMS) {
    assert.deepEqual(Object.keys(PLATFORMS_JSON[p]).sort(), ["configDir", "configDirEnv", "projectSkills", "userSkills"], p);
    for (const v of Object.values(PLATFORMS_JSON[p])) assert.equal(typeof v, "string", p);
  }
});

// skill-dirs.mjs keeps its tables private; its candidate list is own-platform first, so each
// group's first entry is that platform's own value: project dirs, then any relocated user dir,
// then $HOME's.
test("platforms.json agrees with skill-dirs.mjs's PROJECT / USER / CONFIG_DIR_ENV for every platform", () => {
  const root = "/main";
  const home = "/home/u";
  const n = PLATFORMS.length;
  for (const p of PLATFORMS) {
    const { projectSkills, userSkills, configDirEnv } = PLATFORMS_JSON[p];
    const plain = skillDirCandidates(root, p, "s", { HOME: home });
    assert.equal(plain[0], join(root, projectSkills, "s"), `${p}: PROJECT`);
    assert.equal(plain[n], join(home, userSkills, "s"), `${p}: USER`);
    const relocated = skillDirCandidates(root, p, "s", { HOME: home, [configDirEnv]: "/cfg" });
    if (p === "codex") {
      // CONFIG_DIR_ENV has no codex entry: CODEX_HOME relocates no skill dir.
      assert.deepEqual(relocated, plain, `${p}: ${configDirEnv} adds no candidate`);
    } else {
      assert.equal(relocated[n], join("/cfg", "skills", "s"), `${p}: CONFIG_DIR_ENV is ${configDirEnv}`);
      assert.equal(relocated.length, plain.length + 1, `${p}: only ${configDirEnv} relocates`);
    }
  }
});
