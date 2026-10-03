/**
 * Sprint suite — eager dependency provisioning, and what the orchestrator logs about it.
 * Shared helpers: ./helpers/sprint.mjs.
 */

import assert from "node:assert/strict";
import { cpSync, mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { Sprint } from "../../orchestrator/lib/sprint.mjs";
import { REPO, MAIN, SCRIPTS, FAKE, sh, fixtureRepo, addIssue, runSprint, traceLog, state, fake, privateScripts, commandLines, test } from "./helpers/sprint.mjs";

// ─── eager dependency provisioning ───────────────────────────────────────────
//
// dep-install is failure-triggered, which is right for a human's direct solve-issue run.
// A sprint is the opposite case: every worktree is fresh, and one consumer of the deps is
// verify-worktree.sh — a gate, which cannot invoke a skill and has no recovery path when
// `npm test` dies on a missing module. So provisioning is mechanism, at two call sites,
// and what these tests pin is the *position* of those two calls in the recorded command
// order. Only a per-issue `DEPS: failed` changes a round's status: it stops that issue.

/** The effects log — one line per subprocess, in order. CREW_VERBOSE puts it on stderr. */

const SPRINT_LEVEL_DEPS = /ensure-deps\.sh --dir \S+$/;
const worktreeDepsFor = (slug) => new RegExp(`ensure-deps\\.sh --dir \\S+ --slug ${slug} --stem \\d+-${slug}$`);

test("deps are provisioned once per sprint and once per dispatched issue", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  addIssue(root, "02-beta.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  // Once per sprint, against the main root: N parallel worktree installs must not be N
  // cold downloads, so the cache is warmed serially before any worker exists.
  assert.equal(lines.filter((l) => SPRINT_LEVEL_DEPS.test(l)).length, 1);
  // Once per dispatched issue, against that issue's worktree.
  assert.equal(lines.filter((l) => worktreeDepsFor("alpha").test(l)).length, 1);
  assert.equal(lines.filter((l) => worktreeDepsFor("beta").test(l)).length, 1);
});

test("the sprint-level call precedes every worker, and the worktree call precedes both its dispatch and its verify", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const at = (re) => {
    const i = lines.findIndex((l) => re.test(l));
    assert.notEqual(i, -1, `no command matching ${re} in:\n${lines.join("\n")}`);
    return i;
  };
  const sprintDeps = at(SPRINT_LEVEL_DEPS);
  const worktreeDeps = at(worktreeDepsFor("alpha"));
  const worktreeAdd = at(/git .*worktree add/);
  const dispatch = at(/^SPAWN .*--agent crew-coder/);
  const verify = at(/verify-worktree\.sh --dir/);

  assert.ok(sprintDeps < worktreeAdd, "the sprint-level warm-up ran after a worktree existed");
  assert.ok(worktreeAdd < worktreeDeps, "the worktree was provisioned before it existed");
  assert.ok(worktreeDeps < dispatch, "the worker was dispatched into an unprovisioned worktree");
  assert.ok(
    worktreeDeps < verify,
    "verify-worktree.sh ran before deps — the gate has no recovery path of its own",
  );
});

test("a failed per-issue install stops the issue before the coder or verify runs", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  // Sprint-level warm-up (no --slug) succeeds; the issue's own worktree install fails.
  const real = join(scripts, "_real-ensure-deps.sh");
  cpSync(join(scripts, "ensure-deps.sh"), real);
  writeFileSync(
    join(scripts, "ensure-deps.sh"),
    ["#!/usr/bin/env bash", 'case " $* " in *" --slug "*) echo "DEPS: failed npm ci (exit 1)"; exit 0 ;; esac', `exec bash ${JSON.stringify(real)} "$@"`, ""].join("\n"),
  );

  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 0, "the coder ran on an unprovisioned worktree");
  assert.equal(lines.filter((l) => /verify-worktree\.sh --dir/.test(l)).length, 0, "verify ran on an unprovisioned worktree");
  assert.match(`${r.stdout}\n${r.stderr}`, /dependency install failed — failed npm ci \(exit 1\)/);
  assert.deepEqual(state(root).completed_slugs ?? [], []);
});

test("a failed sprint-level docker install stops the run before any worktree or dispatch, even with the baseline on", () => {
  // In docker mode the sprint-level call is the only install: every worktree call only
  // checks it happened. Carrying on would send every coder, and the baseline, to an empty volume.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const real = join(scripts, "_real-ensure-deps.sh");
  cpSync(join(scripts, "ensure-deps.sh"), real);
  writeFileSync(
    join(scripts, "ensure-deps.sh"),
    [
      "#!/usr/bin/env bash",
      'case " $* " in *" --slug "*) exec bash ' + JSON.stringify(real) + ' "$@" ;; esac',
      'echo "make deps runs docker itself, but not through docker-compose.override.yml"',
      'echo "DEPS: docker-failed make deps (exit 5) (see .scratch/docker-install.log)"',
      "",
    ].join("\n"),
  );

  const { r, lines } = commandLines(root, [], { scripts, baseline: true });
  assert.equal(r.code, 1, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /not through docker-compose\.override\.yml/);
  assert.match(r.stderr, /dependencies could not be installed into the docker volume/);
  assert.match(r.stderr, /^  docker-failed make deps \(exit 5\)/m);
  assert.match(r.stderr, /--no-deps/);
  // The log outlives the scrollback: the stop is there too, as the one FATAL line.
  assert.match(traceLog(root), /^\S+Z FATAL \[ABORT\] .*dependencies could not be installed/m);
  assert.equal(lines.filter((l) => /worktree add/.test(l)).length, 0, "a worktree was created");
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-/.test(l)).length, 0, "an agent was dispatched");
});

test("a failed sprint-level host install still stops nothing: every worktree installs again", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const scripts = privateScripts();
  const real = join(scripts, "_real-ensure-deps.sh");
  cpSync(join(scripts, "ensure-deps.sh"), real);
  writeFileSync(
    join(scripts, "ensure-deps.sh"),
    ["#!/usr/bin/env bash", 'case " $* " in *" --slug "*) exec bash ' + JSON.stringify(real) + ' "$@" ;; esac', 'echo "DEPS: failed npm ci (exit 1)"', ""].join("\n"),
  );

  const { r, lines } = commandLines(root, ["--max-rounds", "1"], { scripts });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(lines.filter((l) => /^SPAWN .*--agent crew-coder/.test(l)).length, 1);
});

test("command discovery precedes the sprint-level deps call, so a discovered install override is on disk before ensure-deps.sh's first read", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const at = (re) => {
    const i = lines.findIndex((l) => re.test(l));
    assert.notEqual(i, -1, `no command matching ${re} in:\n${lines.join("\n")}`);
    return i;
  };
  const discovery = at(/discover-commands\.sh$/);
  const cacheWrite = at(/write-commands-cache\.sh --response-file/);
  const sprintDeps = at(SPRINT_LEVEL_DEPS);

  assert.ok(discovery < sprintDeps, "the sprint-level deps call ran before commands were discovered");
  assert.ok(cacheWrite < sprintDeps, "the sprint-level deps call ran before the discovery cache was written");
});

test("a discovered install override is used by the sprint-level deps call, not host-install.sh's own guess", () => {
  // fixtureRepo()'s Makefile has no install/deps target and there is no package.json, so
  // without the discovered override this repo's own dependency step would be DEPS: none.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(
    root,
    "commands.response",
    '{"test": "make test", "lint": "make lint", "typecheck": "make typecheck", "install": "mkdir -p .scratch && touch .scratch/install-ran.marker"}',
  );

  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);

  const cache = JSON.parse(readFileSync(join(root, ".coding-crew/dev-commands.json"), "utf8"));
  assert.equal(cache.install, "mkdir -p .scratch && touch .scratch/install-ran.marker");
  assert.equal(existsSync(join(root, ".scratch/install-ran.marker")), true, "the discovered install command never ran against MAIN_ROOT");
  assert.match(traceLog(root), /\[DEPS\].*installed.*touch \.scratch\/install-ran\.marker/);
});

test("Sprint.installDeps streams ensure-deps.sh's own live output, each line exactly once, then the DEPS summary exactly once", async () => {
  // ensure-deps.sh's own CACHED_INSTALL/docker paths now tee their child's output live (see
  // ensure-deps.sh/docker-install.sh), and installDeps() now streams that through the log
  // callback via spawnWithTimeout's onLine instead of capturing it wholesale and reporting
  // one summary line after the fact — this used to produce zero visible output for however
  // long a real install took. A fake effects.spawnWithTimeout stands in for the real
  // subprocess here, split across two chunks with a line broken mid-chunk, to exercise the
  // buffering logic the same way a real, arbitrarily-chunked stdout stream would.
  const logged = [];
  const fakeEffects = {
    mainRoot: "/fake/root",
    script: (name) => `/fake/scripts/${name}`,
    spawnWithTimeout: async (cmd, args, { onLine } = {}) => {
      onLine("installing-widget-a\ninstall");
      onLine("ing-widget-b\nDEPS: installed echo\n");
      return { code: 0, stdout: "installing-widget-a\ninstalling-widget-b\nDEPS: installed echo\n", stderr: "" };
    },
  };
  const sprint = new Sprint(fakeEffects, {});

  await sprint.installDeps((line) => logged.push(line));

  assert.deepEqual(logged, ["installing-widget-a", "installing-widget-b", "DEPS: installed echo"]);
});

test("the worktree call comes after .worktreeinclude is applied, so an inherited dep dir costs nothing", () => {
  // The presence guard is what makes a .worktreeinclude repo free, and it can only see a
  // linked node_modules if the include has already run.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, ".worktreeinclude"), "node_modules\n");
  writeFileSync(join(root, "package.json"), '{ "name": "fixture", "private": true }\n');
  mkdirSync(join(root, "node_modules"), { recursive: true });
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "add package.json"]);

  const { r, lines } = commandLines(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const include = lines.findIndex((l) => /worktreeinclude|rsync|cp -R/.test(l));
  const deps = lines.findIndex((l) => worktreeDepsFor("alpha").test(l));
  if (include !== -1) assert.ok(include < deps, "deps were provisioned before the include ran");
  assert.match(traceLog(root), /\[DEPS\].*present/);
});

test("--no-deps removes both invocations and nothing else", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const withDeps = commandLines(root);
  assert.equal(withDeps.r.code, 0, withDeps.r.stderr);

  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  const without = commandLines(root2, ["--no-deps"]);
  assert.equal(without.r.code, 0, `${without.r.stdout}\n${without.r.stderr}`);

  assert.equal(without.lines.filter((l) => /ensure-deps\.sh/.test(l)).length, 0);
  // Nothing else changes: the same sequence of scripts, minus the two deps calls.
  const names = (lines) =>
    lines
      .map((l) => (/([\w-]+\.sh)/.exec(l) ?? [])[1] ?? (/--agent (\S+)/.exec(l) ?? [])[1] ?? "git")
      .filter((n) => n !== "ensure-deps.sh");
  assert.deepEqual(names(without.lines), names(withDeps.lines));
});

test("a DEPS: failed outcome blocks the issue at that step, without crashing the sprint", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // A manifest with no dep dir, plus a dep-install stub whose host install always fails.
  writeFileSync(join(root, "package.json"), '{ "name": "fixture", "private": true }\n');
  const stub = join(root, "stub-scripts");
  mkdirSync(stub, { recursive: true });
  writeFileSync(join(stub, "detect-mode.sh"), "#!/usr/bin/env bash\necho USE_HOST\n");
  writeFileSync(join(stub, "host-install.sh"), "#!/usr/bin/env bash\necho 'npm ERR! boom' >&2\nexit 3\n");
  sh("chmod", ["+x", join(stub, "detect-mode.sh"), join(stub, "host-install.sh")]);
  sh("git", ["-C", root, "add", "package.json"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "add package.json"]);

  const r = sh("node", [MAIN, "run", "--platform", "pi", "--feature-slug", "demo", "--no-baseline", "--no-integration-check"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_DEP_INSTALL_SCRIPTS: stub,
    },
  });
  // Stalled (exit 2), not crashed: the issue is blocked with the install's own reason.
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  assert.match(traceLog(root), /\[DEPS\].*failed/);
  const s = state(root);
  assert.deepEqual(s.completed_slugs ?? [], []);
  assert.deepEqual(s.merged_branches ?? [], []);
  assert.match(r.stdout, /Blocked \(1\): alpha/);
  assert.match(readFileSync(join(root, ".scratch/demo/issues/open/01-alpha.md"), "utf8"), /dependency install failed/);
});

test("the orchestrator prints one line per deps call — the DEPS: line itself, slug/round-tagged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const { r } = commandLines(root);
  assert.equal(r.code, 0, r.stderr);
  const printed = r.stderr.split("\n").filter((l) => /\bDEPS:/.test(l));
  assert.equal(printed.length, 2, `expected one line per call, got:\n${printed.join("\n")}`);
  // The per-issue call (not the sprint-level bootstrap one) is slug/round-tagged, so it can
  // be attributed to the right issue and round when interleaved with other issues' output.
  assert.ok(
    printed.some((l) => /^slug=alpha round=1 DEPS:/.test(l)),
    `expected a slug/round-tagged DEPS: line, got:\n${printed.join("\n")}`,
  );
});

test("the orchestrator prints a [STEP] marker before each gate, slug/round-tagged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const steps = r.stderr.split("\n").filter((l) => l.startsWith("[STEP]") && l.includes("slug=01-alpha"));
  // Every gate this clean issue passes through, in the order pipeline.mjs runs them,
  // with no dispatch-triage marker since verify never fails on this path.
  assert.deepEqual(
    steps.map((l) => /step=([\w-]+)/.exec(l)?.[1]),
    ["worktree", "deps", "dispatch-coder", "verify", "dispatch-review", "merge", "close"],
    steps.join("\n"),
  );
  for (const l of steps) assert.match(l, /^\[STEP\] slug=01-alpha round=1 step=[\w-]+( model=\S+ runtime=\S+)?$/, l);
});

test("a dispatch's throttled [TOOL] heartbeat stays off stderr unless CREW_VERBOSE, and is never re-logged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.heartbeat", "");
  const r = runSprint(root, [], { CREW_VERBOSE: "" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stderr, /fake-heartbeat/, "a launcher agent reading stderr pays for every heartbeat");
  // The dispatcher already wrote its own lines to the trace log; the orchestrator adds none.
  assert.doesNotMatch(traceLog(root), /slug=01-alpha round=1 \[TOOL\]/);
});

test("CREW_VERBOSE puts the heartbeat on stderr, slug/round-tagged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.heartbeat", "");
  const r = runSprint(root, [], { CREW_VERBOSE: "1" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const heartbeats = r.stderr.split("\n").filter((l) => l.includes("fake-heartbeat"));
  assert.ok(heartbeats.length >= 1, `expected a heartbeat line reaching stderr:\n${r.stderr}`);
  for (const l of heartbeats) assert.match(l, /^slug=01-alpha round=1 \[TOOL\] agent=\S+ tool=fake-heartbeat/, l);
});

test("stderr leaves out DEBUG lines by default; the trace log keeps them", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_VERBOSE: "", CREW_LOG_LEVEL: "" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  // A script's own stdout, echoed after the script already traced its result line, is debug.
  const echo = /^slug=alpha round=1 DEPS: /m;
  assert.doesNotMatch(r.stderr, echo);
  assert.match(traceLog(root), /^\S+Z DEBUG slug=alpha round=1 DEPS: /m);
  // Progress stays: a launcher answers "how far along?" from [STEP] on stderr.
  assert.match(r.stderr, /^\[STEP\] slug=01-alpha round=1 step=verify$/m);
});

test("CREW_LOG_LEVEL=warn quiets stderr to what went wrong; the trace log is unchanged", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_LOG_LEVEL: "warn" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.doesNotMatch(r.stderr, /\[STEP\]/);
  assert.match(traceLog(root), /^\S+Z INFO  \[STEP\] slug=01-alpha round=1 step=verify$/m);
});

test("CREW_LOG_LEVEL=debug puts the echoes and the heartbeat on stderr, like CREW_VERBOSE", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  fake(root, "alpha.heartbeat", "");
  const r = runSprint(root, [], { CREW_VERBOSE: "", CREW_LOG_LEVEL: "debug" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stderr, /^slug=alpha round=1 DEPS: /m);
  assert.match(r.stderr, /fake-heartbeat/);
});

test("an unknown CREW_LOG_LEVEL warns once on stderr and runs at info", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root, [], { CREW_LOG_LEVEL: "loud" });
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  assert.equal(r.stderr.split("\n").filter((l) => /CREW_LOG_LEVEL=loud/.test(l)).length, 1, r.stderr);
  assert.match(r.stderr, /^\[STEP\] /m);
});

test("an attempt ends in one [ATTEMPT-END] line; no === / --- banners", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  // state.sh's own [ATTEMPT] line is the start; the orchestrator adds no second one.
  assert.equal(log.split("\n").filter((l) => /\[ATTEMPT\] slug=alpha n=1/.test(l)).length, 1, log);
  assert.match(log, /^\S+Z INFO  \[ATTEMPT-END\] slug=alpha attempt=1 status=complete$/m);
  assert.match(r.stderr, /^\[ATTEMPT-END\] slug=alpha attempt=1 status=complete$/m);
  assert.doesNotMatch(`${log}\n${r.stderr}`, /^(=== |--- )slug=/m);
});

test("a verify transcript goes to its own file; the log gets one line pointing at it", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  const r = runSprint(root);
  assert.equal(r.code, 0, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  const m = /^\S+Z DEBUG \[VERIFY-OUTPUT\] slug=alpha round=1 result=pass file=(\S+)$/m.exec(log);
  assert.ok(m, `no [VERIFY-OUTPUT] line:\n${log}`);
  assert.match(readFileSync(join(root, m[1]), "utf8"), /TEST: pass/);
  assert.doesNotMatch(log, /TEST: pass/, "the transcript itself stays out of the log");
});

test("a failed verify's pointer is an ERROR, next to the [VERIFY] result it explains", () => {
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  writeFileSync(join(root, "Makefile"), "test:\n\t@echo boom && exit 1\nlint:\n\t@echo ok\ntypecheck:\n\t@echo ok\n");
  sh("git", ["-C", root, "add", "-A"]);
  sh("git", ["-C", root, "commit", "-q", "-m", "make test always fail"]);
  const r = runSprint(root);
  assert.equal(r.code, 2, `${r.stdout}\n${r.stderr}`);
  const log = traceLog(root);
  const m = /^\S+Z ERROR \[VERIFY-OUTPUT\] slug=alpha round=1 result=fail file=(\S+)$/m.exec(log);
  assert.ok(m, `no failing [VERIFY-OUTPUT] line:\n${log}`);
  assert.match(readFileSync(join(root, m[1]), "utf8"), /TEST: fail/);
  // Each round keeps its own transcript.
  assert.match(log, /\[VERIFY-OUTPUT\] slug=alpha round=2 result=fail file=/);
});

test("--no-deps and the help text are declared together, so the flag is discoverable", () => {
  const help = sh("node", [MAIN, "--help"], { cwd: REPO });
  assert.equal(help.code, 0, help.stderr);
  assert.match(help.stdout, /--no-deps/);
  const source = readFileSync(MAIN, "utf8");
  assert.match(source, /^ \*\s+--no-deps\s/m, "the header comment's option list omits --no-deps");
});

test("a dry run records both call sites without running either", () => {
  // Recorded, not run: --dry-run is the zero-token way to inspect the command sequence, so
  // the two positions have to be visible there too, not only on a live sprint.
  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  // A dry run cannot create the sprint it inspects — session-init.sh is itself an effect.
  sh("bash", [join(SCRIPTS, "session-init.sh"), "--feature-slug", "demo"], {
    cwd: root,
    env: { ...process.env, MAIN_ROOT: root, CREW_SCRIPTS: SCRIPTS },
  });

  const r = sh("node", [MAIN, "run", "--dry-run", "--platform", "pi", "--feature-slug", "demo"], {
    cwd: root,
    env: {
      ...process.env,
      CREW_MAX_ROUNDS: "1",
      CREW_SCRIPTS: SCRIPTS,
      CREW_FAKE_DISPATCH: FAKE,
      CREW_FAKE_DIR: join(root, ".scratch/fake"),
      MAIN_ROOT: root,
      CREW_VERBOSE: "1",
    },
  });
  const dry = r.stderr.split("\n").filter((l) => l.startsWith("DRY "));
  assert.equal(dry.filter((l) => SPRINT_LEVEL_DEPS.test(l)).length, 1, r.stderr);
  assert.equal(dry.filter((l) => worktreeDepsFor("alpha").test(l)).length, 1, r.stderr);
  // Recorded only: no install ran, so no marker and no dep dir appeared anywhere.
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/deps.ok")), false);
  assert.equal(existsSync(join(root, ".scratch/demo/dispatch/01-alpha/deps.skip")), false);
});

test("a worktree that starts with no node_modules is verified and merged, with no worker recovery", () => {
  // The failure this whole feature exists for, reproduced: verify-worktree.sh runs the
  // project's own check in the worktree, the check needs the dep dir, and the gate has no
  // way to install it. Before eager provisioning this round ended `verification-failed`
  // with the branch retained and nothing merged, however healthy the worker's report was.
  //
  // The fixture's dependency step is its own `make install`, which is the first thing
  // host-install.sh looks for — so this exercises the real detect-mode → host-install path
  // with no network and no package registry in the loop.
  const files = {
    Makefile: [
      "install:",
      "\t@mkdir -p node_modules && touch node_modules/.stamp",
      // The check *is* the assertion: it can only pass if something installed deps first.
      "test:",
      "\t@test -f node_modules/.stamp && echo ok",
      "lint:",
      "\t@echo ok",
      "typecheck:",
      "\t@echo ok",
      "",
    ].join("\n"),
    "package.json": '{ "name": "fixture", "version": "1.0.0", "private": true }\n',
    ".gitignore": ".scratch/\nnode_modules/\n",
  };
  const seed = (root) => {
    for (const [name, body] of Object.entries(files)) writeFileSync(join(root, name), body);
    sh("git", ["-C", root, "add", "-A"]);
    sh("git", ["-C", root, "commit", "-q", "-m", "add a dependency step"]);
  };

  const root = fixtureRepo();
  addIssue(root, "01-alpha.md");
  seed(root);
  assert.equal(existsSync(join(root, "node_modules")), false, "the fixture must start bare");

  // Pinned to this source tree's own dep-install scripts, not whatever a contributor's local
  // .coding-crew self-install happens to have on disk (_find_dep_scripts prefers that over
  // skills/dep-install/scripts when neither is stubbed) — otherwise this test's outcome
  // depends on which release .coding-crew was last installed from, not on this source.
  const depScripts = { env: { CREW_DEP_INSTALL_SCRIPTS: join(REPO, "skills/dep-install/scripts") } };
  const r = commandLines(root, [], depScripts);
  assert.equal(r.r.code, 0, `${r.r.stdout}\n${r.r.stderr}`);
  const s = state(root);
  assert.deepEqual(s.completed_slugs, ["alpha"], "the branch did not merge — see the DEPS: line");
  assert.deepEqual(s.merged_branches, ["crew/demo/alpha"]);
  // Provisioned by the pipeline, not recovered from by the worker.
  assert.match(traceLog(root), /\[DEPS\].*installed.*make install/);
  assert.match(traceLog(root), /\[VERIFY\].*result=pass/);

  // And with --no-deps the same repo fails at the gate, which is what makes the above a
  // result of the two call sites rather than of anything else in the fixture.
  const root2 = fixtureRepo();
  addIssue(root2, "01-alpha.md");
  seed(root2);
  const off = commandLines(root2, ["--no-deps"], depScripts);
  assert.equal(off.r.code, 2, "without deps the issue never passes verify, so it spends both attempts and blocks");
  assert.deepEqual(state(root2).merged_branches ?? [], []);
  assert.equal(state(root2).retention.alpha.reason, "blocked — retry limit reached (2 attempts) — verification-failed");

  // The retry cap is per invocation, not permanent: crew-summary.sh tells a human to
  // "resolve blockers and re-run" for exactly this reason. Drop --no-deps (the "fix") and
  // re-run — a blocked issue must still be picked up and given a fresh attempt budget, not
  // skipped forever because a *prior* process already spent its two attempts.
  const retry = commandLines(root2, [], depScripts);
  assert.equal(retry.r.code, 0, `${retry.r.stdout}\n${retry.r.stderr}`);
  assert.deepEqual(state(root2).completed_slugs, ["alpha"]);
  assert.deepEqual(state(root2).blocked_slugs ?? [], []);
});
