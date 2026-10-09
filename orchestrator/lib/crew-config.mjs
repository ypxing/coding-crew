/**
 * crew-config.mjs — .coding-crew/config.json, and which runtime and model each crew-afk role
 * runs on.
 *
 * config.json holds user-authored coding-crew settings, one top-level section per consumer.
 * Caches (dev-commands.json) and installer state (manifest.json) are separate files. It is read
 * at two levels, the same two a coding-crew install has: ~/.coding-crew/config.json (this
 * machine: e.g. a provider-specific model ID, or which runtime you have) under the repo's own
 * (team policy, committed). They merge per setting, the repo's winning; CLI flags win over both.
 * Sections: `afk`, below, and `tracker` (`{"kind": "local"|"github"}`), which only the repo's
 * file may hold — which tracker a repo uses is the team's — and which tracker/tracker-config.mjs
 * reads and validates; here it is only allowed through. `afk`:
 *
 *   { "afk": {
 *       "runtime": { "reviewer": "codex" },
 *       "models":  { "claude": { "coder": "sonnet" }, "codex": { "reviewer": "gpt-5.1-codex" } },
 *       "fixFindings": "actionable",
 *       "timeouts": { "coder": 60 }, "maxParallel": 3, "maxWallMinutes": 120, "installDeps": true, "squashCommits": false,
 *       "openPr": false,
 *       "baselineCheck": true, "integrationCheck": true, "resumeCoderSession": false,
 *       "branchPrefix": "feature/",
 *       "limits": { "coder": { "usd": 5 } } } }
 *
 * Every setting but runtime/models/limits has a flag that wins for one run (resolveSettings).
 *
 * The PRD audit's settings (afk.PRDAudit, and the prdAuditor role under runtime/models/timeouts/
 * limits) are accepted and ignored, one notice each (dropRetired): the feature review checks PRD
 * coverage now, and a config written for the audit keeps loading.
 *
 * `limits.<role>.usd` caps one dispatch of that role in dollars — the runtime adapter's `budget`
 * flag (claude's --max-budget-usd), a backstop, off by default. A role on a runtime whose adapter
 * has no `budget` ignores it, and main.mjs says so once per run. A dispatch that hits it blocks its issue as `limit-exceeded`.
 *
 * `paneHost` ("orca" | "herdr" | "auto" | "none") describes this machine, not the team, so only
 * ~/.coding-crew/config.json may set it; the repo's file is rejected for it. It also has an env
 * layer between flag and file (resolvePaneHost).
 *
 * `worktreeRoot` (absolute, or relative to the repo root) is where per-issue worktrees are
 * created; unset keeps `.scratch/worktrees`. Either file may set it, and CREW_WORKTREE_ROOT
 * wins over both (resolveWorktreeRoot). No flag: it is a standing choice, not a per-run one.
 *
 * `branchPrefix` (any string, "" allowed; unset is session-init.sh's `feature/`) starts the name
 * of a feature branch a run creates: `<branchPrefix>[<--jira KEY>-]<feature-slug>`. Either file
 * may set it; no flag, for the same reason as worktreeRoot. session-init.sh validates the
 * finished name (`git check-ref-format --branch`).
 *
 * A model string belongs to one runtime, so it's filed under it and never passed to another
 * runtime's CLI. A role that moves to another runtime therefore does not inherit the coder's
 * model: with nothing named under its own runtime, it gets that runtime's default, or no
 * --model at all, so the CLI picks one.
 *
 * Aliases are passed through, not resolved: a Claude alias maps through the child CLI's own
 * ANTHROPIC_DEFAULT_*_MODEL env or settings, which every dispatch inherits. So a committed
 * config.json names aliases, and per-machine provider IDs stay in env.
 *
 * Deliberately no capability ranking across arbitrary model strings. The only order used is an
 * adapter's own `modelTiers` (Claude Code's aliases), for an advisory warning.
 *
 * .coding-crew/afk-models.json, the claude-only file this replaces, is moved into
 * `afk.models.claude` the first time `run` sees it. Its values only ever applied on claude, so
 * that is the same behaviour on every platform.
 */
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { preflight } from "./dispatch.mjs";
import { ADAPTERS, PLATFORMS } from "./adapters/index.mjs";
import { ROLE_POLICY } from "./adapters/render.mjs";

export const CONFIG_REL = ".coding-crew/config.json";
export const USER_CONFIG_LABEL = "~/.coding-crew/config.json";
export const LEGACY_REL = ".coding-crew/afk-models.json";

export const ROLES = ["coder", "reviewer", "triage", "commandFinder", "prWriter"];
const SECTIONS = ["afk", "tracker"];
// Sections only the repo's config.json may hold (USER_ONLY's reverse).
const REPO_ONLY_SECTIONS = ["tracker"];

// What review findings are fixed automatically — `actionable`: every finding crew-triage judges
// Actionable, whatever its severity; the others: the lowest severity.
export const FIX_FINDINGS = ["actionable", "critical", "high", "medium", "none"];
/** Minutes. Every LLM role, plus the merge/close step, which blocks the event loop. */
export const DEFAULT_TIMEOUTS = { coder: 60, reviewer: 20, triage: 20, commandFinder: 5, prWriter: 10, merge: 5 };
// setTimeout fires at once past 2^31-1 ms, so a longer timeout would kill every dispatch.
export const MAX_TIMEOUT_MINUTES = Math.floor((2 ** 31 - 1) / 60_000);
const timeoutProblem = (min) =>
  typeof min === "number" && min > 0 && min <= MAX_TIMEOUT_MINUTES
    ? null
    : `must be a positive number of minutes, at most ${MAX_TIMEOUT_MINUTES}`;
// The roles with a ROLE_POLICY (adapters/render.mjs), so the ones afk.effort may set.
const effortRoles = () => Object.keys(ROLE_POLICY);
export const PANE_HOSTS = ["orca", "herdr", "auto", "none"];
export const DEFAULT_SETTINGS = {
  fixFindings: "actionable",
  installDeps: true,
  squashCommits: false,
  openPr: false,
  baselineCheck: true,
  integrationCheck: true,
  resumeCoderSession: false,
  maxWallMinutes: 120,
};

// Settings that are one value each, merged by replacement; `check` returns a problem or null.
const SCALARS = {
  fixFindings: (v) => (FIX_FINDINGS.includes(v) ? null : `is ${JSON.stringify(v)} (expected ${FIX_FINDINGS.join(", ")})`),
  maxParallel: (v) => (Number.isInteger(v) && v > 0 ? null : "must be a positive integer"),
  maxWallMinutes: (v) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? null : "must be a number of minutes, 0 or more (0 disables the cap)"),
  installDeps: (v) => (typeof v === "boolean" ? null : "must be true or false"),
  squashCommits: (v) => (typeof v === "boolean" ? null : "must be true or false"),
  openPr: (v) => (typeof v === "boolean" ? null : "must be true or false"),
  baselineCheck: (v) => (typeof v === "boolean" ? null : "must be true or false"),
  integrationCheck: (v) => (typeof v === "boolean" ? null : "must be true or false"),
  resumeCoderSession: (v) => (typeof v === "boolean" ? null : "must be true or false"),
  paneHost: (v) => (PANE_HOSTS.includes(v) ? null : `is ${JSON.stringify(v)} (expected ${PANE_HOSTS.join(", ")})`),
  worktreeRoot: (v) => (typeof v === "string" && v.trim() ? null : "must be a non-empty path"),
  branchPrefix: (v) => (typeof v === "string" ? null : `must be a string ("" for none), got ${JSON.stringify(v)}`),
};
// Per-machine settings: accepted from ~/.coding-crew/config.json only.
const USER_ONLY = ["paneHost"];
const AFK_KEYS = ["runtime", "models", "timeouts", "effort", "limits", ...Object.keys(SCALARS)];

// afk-models.json's role names, before the plain-dispatch roles were renamed.
const LEGACY_ROLE_NAMES = { commandsDiscovery: "commandFinder" };

// The PRD audit's role, gone with it; its settings still load (dropRetired).
const RETIRED_ROLE = "prdAuditor";
export const retiredNotice = (name) => `\`${name}\` no longer does anything: the feature review checks PRD coverage.`;

// A runtime's model when nothing names one is its adapter's `defaultModel`, resolved here so
// that an unconfigured sprint's reviewer/triage genuinely match what the coder runs on, and the
// tier check below sees it.
const defaultModel = (adapters, runtime) => adapters[runtime]?.defaultModel ?? null;

export class ConfigError extends Error {}

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function readJson(path, rel) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new ConfigError(`${rel} is not valid JSON (${err.message})`);
  }
}

/**
 * Every problem in one message, so a user fixes the file once rather than once per run.
 * `userLevel`: the file is ~/.coding-crew/config.json, so USER_ONLY settings are allowed.
 */
export function validateConfig(config, label = CONFIG_REL, { userLevel = label === USER_CONFIG_LABEL } = {}) {
  const problems = [];
  const oneOf = (list) => list.join(", ");
  if (!isObject(config)) throw new ConfigError(`${label} must be a JSON object`);
  for (const k of Object.keys(config)) {
    if (!SECTIONS.includes(k)) problems.push(`unknown section "${k}" (expected ${oneOf(SECTIONS)})`);
    else if (REPO_ONLY_SECTIONS.includes(k) && label === USER_CONFIG_LABEL) {
      problems.push(`"${k}" belongs to the repo — set it in its ${CONFIG_REL}, not ${USER_CONFIG_LABEL}`);
    }
  }
  const afk = config.afk;
  if (afk !== undefined) {
    if (!isObject(afk)) problems.push(`"afk" must be an object`);
    else {
      for (const k of Object.keys(afk)) {
        if (!AFK_KEYS.includes(k)) problems.push(`unknown key "afk.${k}" (expected ${oneOf(AFK_KEYS)})`);
      }
      if (afk.runtime !== undefined) {
        if (!isObject(afk.runtime)) problems.push(`"afk.runtime" must be an object of role → runtime`);
        else {
          for (const [role, rt] of Object.entries(afk.runtime)) {
            if (!ROLES.includes(role)) problems.push(`unknown role "afk.runtime.${role}" (expected ${oneOf(ROLES)})`);
            if (!PLATFORMS.includes(rt)) problems.push(`"afk.runtime.${role}" is ${JSON.stringify(rt)} (expected ${oneOf(PLATFORMS)})`);
          }
        }
      }
      for (const [k, check] of Object.entries(SCALARS)) {
        const problem = afk[k] === undefined ? null : check(afk[k]);
        if (problem) problems.push(`"afk.${k}" ${problem}`);
        else if (afk[k] !== undefined && !userLevel && USER_ONLY.includes(k)) {
          problems.push(`"afk.${k}" is per-machine — set it in ${USER_CONFIG_LABEL}, not the repo's config`);
        }
      }
      if (afk.timeouts !== undefined) {
        if (!isObject(afk.timeouts)) problems.push(`"afk.timeouts" must be an object of role → minutes`);
        else {
          for (const [k, min] of Object.entries(afk.timeouts)) {
            if (!Object.hasOwn(DEFAULT_TIMEOUTS, k)) problems.push(`unknown key "afk.timeouts.${k}" (expected ${oneOf(Object.keys(DEFAULT_TIMEOUTS))})`);
            const problem = timeoutProblem(min);
            if (problem) problems.push(`"afk.timeouts.${k}" ${problem}`);
          }
        }
      }
      if (afk.effort !== undefined) {
        if (!isObject(afk.effort)) problems.push(`"afk.effort" must be an object of role → effort`);
        else {
          for (const [role, effort] of Object.entries(afk.effort)) {
            if (!effortRoles().includes(role)) problems.push(`unknown role "afk.effort.${role}" (expected ${oneOf(effortRoles())})`);
            if (typeof effort !== "string" || !effort.trim()) problems.push(`"afk.effort.${role}" must be a non-empty string`);
          }
        }
      }
      if (afk.limits !== undefined) {
        if (!isObject(afk.limits)) problems.push(`"afk.limits" must be an object of role → { "usd": <dollars> }`);
        else {
          for (const [role, limit] of Object.entries(afk.limits)) {
            if (!ROLES.includes(role)) problems.push(`unknown role "afk.limits.${role}" (expected ${oneOf(ROLES)})`);
            if (!isObject(limit)) {
              problems.push(`"afk.limits.${role}" must be an object like { "usd": 5 }`);
              continue;
            }
            for (const k of Object.keys(limit)) {
              if (k !== "usd") problems.push(`unknown key "afk.limits.${role}.${k}" (expected usd)`);
            }
            if (!(typeof limit.usd === "number" && Number.isFinite(limit.usd) && limit.usd > 0)) {
              problems.push(`"afk.limits.${role}.usd" must be a positive number of dollars`);
            }
          }
        }
      }
      if (afk.models !== undefined) {
        if (!isObject(afk.models)) problems.push(`"afk.models" must be an object of runtime → { role: model }`);
        else {
          for (const [rt, byRole] of Object.entries(afk.models)) {
            if (!PLATFORMS.includes(rt)) problems.push(`unknown runtime "afk.models.${rt}" (expected ${oneOf(PLATFORMS)})`);
            if (!isObject(byRole)) {
              problems.push(`"afk.models.${rt}" must be an object of role → model`);
              continue;
            }
            for (const [role, model] of Object.entries(byRole)) {
              if (!ROLES.includes(role)) problems.push(`unknown role "afk.models.${rt}.${role}" (expected ${oneOf(ROLES)})`);
              if (typeof model !== "string" || !model.trim()) problems.push(`"afk.models.${rt}.${role}" must be a non-empty string`);
            }
          }
        }
      }
    }
  }
  if (problems.length) throw new ConfigError(`${label}: ${problems.join("; ")}`);
}

/**
 * `config` without the retired PRD audit's settings, one notice in `notices` per setting dropped,
 * so a config written for the audit loads instead of failing as an unknown key.
 */
function dropRetired(config, label, notices) {
  if (!isObject(config) || !isObject(config.afk)) return config;
  const afk = { ...config.afk };
  const named = [];
  const without = (byRole, path) => {
    if (!isObject(byRole) || !Object.hasOwn(byRole, RETIRED_ROLE)) return byRole;
    named.push(`${path}.${RETIRED_ROLE}`);
    const { [RETIRED_ROLE]: _, ...rest } = byRole;
    return rest;
  };
  if (Object.hasOwn(afk, "PRDAudit")) {
    delete afk.PRDAudit;
    named.push("afk.PRDAudit");
  }
  for (const k of ["runtime", "timeouts", "limits", "effort"]) if (afk[k] !== undefined) afk[k] = without(afk[k], `afk.${k}`);
  if (isObject(afk.models)) {
    afk.models = Object.fromEntries(Object.entries(afk.models).map(([rt, byRole]) => [rt, without(byRole, `afk.models.${rt}`)]));
  }
  for (const n of named) notices.push(`${label}: ${retiredNotice(n)}`);
  return { ...config, afk };
}

/** Every afk leaf a file sets: "runtime.<role>", "models.<runtime>.<role>", "timeouts.<k>", "effort.<role>", "limits.<role>.usd", "<scalar>". */
function afkLeaves(afk = {}) {
  const leaves = Object.keys(afk.runtime ?? {}).map((role) => `runtime.${role}`);
  for (const [rt, byRole] of Object.entries(afk.models ?? {})) {
    for (const role of Object.keys(byRole)) leaves.push(`models.${rt}.${role}`);
  }
  for (const k of Object.keys(afk.timeouts ?? {})) leaves.push(`timeouts.${k}`);
  for (const k of Object.keys(afk.effort ?? {})) leaves.push(`effort.${k}`);
  for (const role of Object.keys(afk.limits ?? {})) leaves.push(`limits.${role}.usd`);
  for (const k of Object.keys(SCALARS)) if (afk[k] !== undefined) leaves.push(k);
  return leaves;
}

/** `over` on top of `base`, one setting at a time, so a repo naming one role keeps the rest of yours. */
function mergeAfk(base = {}, over = {}) {
  const runtime = { ...base.runtime, ...over.runtime };
  const timeouts = { ...base.timeouts, ...over.timeouts };
  const limits = { ...base.limits, ...over.limits };
  const effort = { ...base.effort, ...over.effort };
  const models = {};
  for (const rt of new Set([...Object.keys(base.models ?? {}), ...Object.keys(over.models ?? {})])) {
    models[rt] = { ...base.models?.[rt], ...over.models?.[rt] };
  }
  const scalars = {};
  for (const k of Object.keys(SCALARS)) {
    const v = over[k] ?? base[k];
    if (v !== undefined) scalars[k] = v;
  }
  return {
    ...(Object.keys(runtime).length ? { runtime } : {}),
    ...(Object.keys(models).length ? { models } : {}),
    ...(Object.keys(timeouts).length ? { timeouts } : {}),
    ...(Object.keys(effort).length ? { effort } : {}),
    ...(Object.keys(limits).length ? { limits } : {}),
    ...scalars,
  };
}

/**
 * Read the repo's config.json, moving a legacy afk-models.json into it in memory. The move on
 * disk is `legacyMove.apply()`, left to the caller so a run can do it only once setup has passed.
 */
function loadProjectConfig(mainRoot, notices, { userLevel = false } = {}) {
  let legacyMove = null;
  const path = join(mainRoot, CONFIG_REL);
  const legacyPath = join(mainRoot, LEGACY_REL);
  let config = existsSync(path) ? readJson(path, CONFIG_REL) : {};
  // Before the legacy move, which would otherwise overwrite a non-object file.
  if (!isObject(config)) throw new ConfigError(`${CONFIG_REL} must be a JSON object`);

  if (existsSync(legacyPath)) {
    if (config.afk !== undefined) {
      notices.push(`${LEGACY_REL} is ignored — ${CONFIG_REL} already has an "afk" section. Delete ${LEGACY_REL}.`);
    } else {
      const legacy = readJson(legacyPath, LEGACY_REL);
      if (!isObject(legacy)) throw new ConfigError(`${LEGACY_REL} must be a JSON object`);
      // Checked in the old file's own terms, so the error names the key the user wrote. An
      // unknown key was ignored by the old loader, so it is dropped with a notice, not fatal.
      const claude = {};
      const problems = [];
      for (const [key, model] of Object.entries(legacy)) {
        const role = LEGACY_ROLE_NAMES[key] ?? key;
        if (!ROLES.includes(role)) notices.push(`${LEGACY_REL}: unknown key "${key}" is dropped in the move.`);
        else if (model === null) continue; // the old file's "inherit", which absent now means
        else if (typeof model !== "string" || !model.trim()) problems.push(`"${key}" must be a non-empty string`);
        else claude[role] = model;
      }
      if (problems.length) throw new ConfigError(`${LEGACY_REL}: ${problems.join("; ")}`);
      config = { ...config, afk: { models: { claude } } };
      validateConfig(config);
      const moved = config;
      legacyMove = {
        pending: `${LEGACY_REL} will be moved into ${CONFIG_REL} (afk.models.claude) on the next \`run\`.`,
        apply() {
          writeFileSync(path, `${JSON.stringify(moved, null, 2)}\n`);
          unlinkSync(legacyPath);
          return `moved ${LEGACY_REL} into ${CONFIG_REL} (afk.models.claude) — commit it.`;
        },
      };
    }
  }

  config = dropRetired(config, CONFIG_REL, notices);
  validateConfig(config, CONFIG_REL, { userLevel });
  return { config, legacyMove };
}

/**
 * The user's config under the repo's, merged per setting.
 * @returns {{config: object, origin: Record<string, "user"|"project">, notices: string[],
 *   legacyMove: {pending: string, apply: () => string}|null}}
 *   origin names which file set each afk leaf ("runtime.reviewer", "models.claude.coder");
 *   legacyMove is a pending afk-models.json move (`write: true` applies it at once instead);
 *   throws ConfigError, naming the file, on an invalid one
 */
export function loadConfig(mainRoot, { write = false, home = process.env.HOME || homedir() } = {}) {
  const notices = [];
  // A repo at $HOME (a user-level install's own root) is one file, read once, as the repo's.
  // Read first: an invalid user file must fail the run before the legacy move writes anything.
  const userPath = join(home, CONFIG_REL);
  let user = {};
  const atHome = resolve(userPath) === resolve(join(mainRoot, CONFIG_REL));
  if (!atHome && existsSync(userPath)) {
    user = dropRetired(readJson(userPath, USER_CONFIG_LABEL), USER_CONFIG_LABEL, notices);
    validateConfig(user, USER_CONFIG_LABEL);
  }
  const { config: project, legacyMove } = loadProjectConfig(mainRoot, notices, { userLevel: atHome });
  if (legacyMove && write) notices.push(legacyMove.apply());

  const origin = {};
  for (const leaf of afkLeaves(user.afk)) origin[leaf] = "user";
  for (const leaf of afkLeaves(project.afk)) origin[leaf] = "project";
  const config = { ...user, ...project };
  if (user.afk || project.afk) config.afk = mergeAfk(user.afk, project.afk);
  return { config, origin, notices, legacyMove: write ? null : legacyMove };
}

/**
 * Each role's runtime and model.
 * @returns {{roles: Record<string, {runtime: string, model: string|null}>, warnings: string[]}}
 */
export function resolveCrew({ afk = {}, cliPlatform, cliModel = null, adapters = ADAPTERS }) {
  const warnings = [];
  const models = afk.models ?? {};
  const runtimeOf = (role) => afk.runtime?.[role] ?? cliPlatform;
  const coderRuntime = runtimeOf("coder");

  const onLauncher = (rt) => (rt === cliPlatform ? cliModel : null);
  const coderModel = onLauncher(coderRuntime) ?? models[coderRuntime]?.coder ?? defaultModel(adapters, coderRuntime);

  const roles = { coder: { runtime: coderRuntime, model: coderModel } };
  for (const role of ROLES.slice(1)) {
    const runtime = runtimeOf(role);
    const inherited = runtime === coderRuntime ? coderModel : (onLauncher(runtime) ?? defaultModel(adapters, runtime));
    roles[role] = { runtime, model: models[runtime]?.[role] ?? inherited };
  }

  // --model is in the launcher's vocabulary, so it only reaches roles on the launcher's runtime.
  if (cliModel && coderRuntime !== cliPlatform) {
    const takers = ROLES.filter((r) => roles[r].runtime === cliPlatform && roles[r].model === cliModel);
    warnings.push(
      `--model ${cliModel} is ignored for the coder: it runs on ${coderRuntime} (afk.runtime.coder), ` +
        `not ${cliPlatform}. Name its model under afk.models.${coderRuntime}.coder.` +
        (takers.length ? ` It still applies to ${takers.join(", ")}, on ${cliPlatform}.` : ""),
    );
  }

  // Tiers compare only within the coder's runtime, and only where its adapter ranks its models.
  const tiers = adapters[coderRuntime]?.modelTiers;
  for (const role of ROLES.slice(1)) {
    const { runtime, model } = roles[role];
    if (
      tiers &&
      runtime === coderRuntime &&
      model !== coderModel &&
      Object.hasOwn(tiers, model) &&
      Object.hasOwn(tiers, coderModel) &&
      tiers[model] < tiers[coderModel]
    ) {
      warnings.push(
        `${role} model "${model}" is a weaker tier than coder model "${coderModel}" — the ` +
          "standard that role holds the branch to may be lower than intended.",
      );
    }
  }
  return { roles, warnings };
}

/** "sonnet (→ <id>, ANTHROPIC_DEFAULT_SONNET_MODEL)" when this process can see the runtime adapter's alias mapping. */
export function describeModel(runtime, model, env = process.env, adapters = ADAPTERS) {
  if (!model) return "runtime default";
  const envName = adapters[runtime]?.modelAliasEnv?.[model];
  return envName && env[envName] ? `${model} (→ ${env[envName]}, ${envName})` : model;
}

/** The roles a run dispatches: the command finder and the PR writer are each optional. */
export function activeRoles({ commands = true, openPr = DEFAULT_SETTINGS.openPr } = {}) {
  return ROLES.filter((r) => (r !== "commandFinder" || commands) && (r !== "prWriter" || openPr));
}

// The flag that overrides each setting, for error text.
const FLAG_FOR = {
  fixFindings: "--fix-findings",
  maxParallel: "--max-parallel",
  maxWallMinutes: "--max-wall",
  paneHost: "--pane-host",
  "timeouts.coder": "--coder-timeout",
  "timeouts.reviewer": "--reviewer-timeout",
};

/**
 * A bad flag value, checked by the same rules as its config.json setting — and a bad
 * CREW_PANE_HOST, the one setting with an env layer.
 */
export function validateFlags(cli = {}, flagOf = {}, env = process.env) {
  const problems = [];
  if (env.CREW_PANE_HOST) {
    const problem = SCALARS.paneHost(env.CREW_PANE_HOST);
    if (problem) problems.push(`CREW_PANE_HOST ${problem}`);
  }
  const name = (k) => flagOf[k] ?? FLAG_FOR[k] ?? k;
  for (const [k, check] of Object.entries(SCALARS)) {
    const problem = cli[k] === undefined ? null : check(cli[k]);
    if (problem) problems.push(`${name(k)} ${problem}`);
  }
  for (const [k, min] of Object.entries(cli.timeouts ?? {})) {
    const problem = timeoutProblem(min);
    if (problem) problems.push(`${name(`timeouts.${k}`)} ${problem}`);
  }
  return [...new Set(problems)];
}

/**
 * The sprint's settings: each flag (`cli`, undefined when not given) over config.json's
 * afk section over the defaults. `origin` gains "--flag" for each setting a flag decided,
 * so `plan` credits the right source.
 * @returns {{fixFindings, installDeps, squashCommits, openPr, baselineCheck, integrationCheck, resumeCoderSession,
 *   maxParallel: number|null,
 *   branchPrefix: string|null,  null: session-init.sh's default
 *   timeouts: Record<string, number>,  timeouts in minutes
 *   effort: Record<string, string>,  each ROLE_POLICY role → afk.effort, else ROLE_POLICY's
 *   limitsUsd: Record<string, number>}}  each capped role's dollar cap; no key, no cap
 */
export function resolveSettings({ afk = {}, cli = {}, origin = {} }) {
  const pick = (k) => {
    if (cli[k] !== undefined) {
      origin[k] = "flag";
      return cli[k];
    }
    return afk[k] ?? DEFAULT_SETTINGS[k] ?? null;
  };
  const timeouts = {};
  for (const [k, def] of Object.entries(DEFAULT_TIMEOUTS)) {
    if (cli.timeouts?.[k] !== undefined) origin[`timeouts.${k}`] = "flag";
    timeouts[k] = cli.timeouts?.[k] ?? afk.timeouts?.[k] ?? def;
  }
  const effort = {};
  for (const role of effortRoles()) {
    effort[role] = afk.effort?.[role] ?? ROLE_POLICY[role].effort;
  }
  return {
    effort,
    fixFindings: pick("fixFindings"),
    installDeps: pick("installDeps"),
    squashCommits: pick("squashCommits"),
    openPr: pick("openPr"),
    baselineCheck: pick("baselineCheck"),
    integrationCheck: pick("integrationCheck"),
    resumeCoderSession: pick("resumeCoderSession"),
    maxParallel: pick("maxParallel"),
    maxWallMinutes: pick("maxWallMinutes"),
    branchPrefix: pick("branchPrefix"),
    timeouts,
    limitsUsd: Object.fromEntries(Object.entries(afk.limits ?? {}).map(([role, l]) => [role, l.usd])),
  };
}

/**
 * The one line a run prints for the dollar caps it cannot apply: a capped role on a runtime whose
 * adapter has no `budget` runs uncapped. Null when every cap applies.
 */
export function ignoredLimitsNotice(limitsUsd = {}, crew, adapters = ADAPTERS) {
  const ignored = Object.keys(limitsUsd).filter((role) => crew[role] && !adapters[crew[role].runtime]?.budget);
  if (!ignored.length) return null;
  const which = ignored.map((role) => `${role} (${crew[role].runtime})`).join(", ");
  const runtimes = [...new Set(ignored.map((role) => crew[role].runtime))].join(", ");
  return `afk.limits ignored for ${which} — a per-dispatch dollar cap is not supported by ${runtimes}.`;
}

/**
 * The pane host: --pane-host, else CREW_PANE_HOST, else the legacy ORCA_ENV=1 / HERDR_ENV=1
 * (orca first), else ~/.coding-crew/config.json's afk.paneHost. "auto" picks the host whose
 * ambient terminal id is in env — opt-in, since running inside a herdr pane is not asking for
 * herdr. `origin.paneHost` names the source for `plan`.
 * @returns {{paneHost: "orca"|"herdr"|null, notices: string[]}}
 */
export function resolvePaneHost({ afk = {}, cli = {}, env = process.env, origin = {} }) {
  const notices = [];
  let choice;
  if (cli.paneHost !== undefined) {
    choice = cli.paneHost;
    origin.paneHost = "flag";
  } else if (env.CREW_PANE_HOST) {
    choice = env.CREW_PANE_HOST;
    origin.paneHost = "CREW_PANE_HOST";
  } else if (env.ORCA_ENV === "1") {
    choice = "orca";
    origin.paneHost = "ORCA_ENV";
    if (env.HERDR_ENV === "1") notices.push("ORCA_ENV=1 and HERDR_ENV=1 are both set — using orca (set CREW_PANE_HOST to choose).");
  } else if (env.HERDR_ENV === "1") {
    choice = "herdr";
    origin.paneHost = "HERDR_ENV";
  } else {
    choice = afk.paneHost ?? "none";
  }
  if (choice === "auto") {
    choice = env.ORCA_TERMINAL_HANDLE ? "orca" : env.HERDR_PANE_ID ? "herdr" : "none";
  }
  return { paneHost: choice === "none" ? null : choice, notices };
}

/**
 * The worktree root as the user wrote it: CREW_WORKTREE_ROOT, else config.json's
 * afk.worktreeRoot, else null for worktree.mjs's default. `origin.worktreeRoot` names the
 * source for `plan`.
 * @returns {string|null}
 */
export function resolveWorktreeRoot({ afk = {}, env = process.env, origin = {} }) {
  if (env.CREW_WORKTREE_ROOT) {
    origin.worktreeRoot = "CREW_WORKTREE_ROOT";
    return env.CREW_WORKTREE_ROOT;
  }
  return afk.worktreeRoot ?? null;
}

/**
 * preflight() once per runtime the active roles use. A problem on a runtime other
 * than the launcher's names its roles, since the user chose that runtime in config.json.
 */
export function crewPreflight(effects, mainRoot, { crew, roles, launcher, paneHost = null, probeFlags = false }) {
  const byRuntime = new Map();
  for (const role of roles) {
    const { runtime } = crew[role];
    if (!byRuntime.has(runtime)) byRuntime.set(runtime, []);
    byRuntime.get(runtime).push(role);
  }
  const problems = [];
  for (const [runtime, bound] of byRuntime) {
    const found = preflight(effects, runtime, { paneHost, probeFlags });
    paneHost = null; // checked once, not once per runtime
    const tag = runtime === launcher ? "" : `${bound.join(", ")} → ${runtime}: `;
    problems.push(...found.map((p) => `${tag}${p}`));
  }
  return problems;
}
