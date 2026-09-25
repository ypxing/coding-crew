/**
 * crew-config.mjs — .coding-crew/config.json, and which runtime and model each crew-afk role
 * runs on.
 *
 * config.json holds user-authored coding-crew settings, one top-level section per consumer.
 * Caches (dev-commands.json) and installer state (manifest.json) are separate files. It is read
 * at two levels, the same two a coding-crew install has: ~/.coding-crew/config.json (this
 * machine: e.g. a provider-specific model ID, or which runtime you have) under the repo's own
 * (team policy, committed). They merge per setting, the repo's winning; CLI flags win over both.
 * The only section today is `afk`:
 *
 *   { "afk": {
 *       "runtime": { "reviewer": "codex" },
 *       "models":  { "claude": { "coder": "sonnet" }, "codex": { "reviewer": "gpt-5.1-codex" } },
 *       "fixFindings": "high", "PRDAudit": "fix",
 *       "timeouts": { "coder": 45 }, "maxParallel": 3, "installDeps": true, "squashCommits": true } }
 *
 * Every setting but runtime/models has a flag that wins for one run (resolveSettings).
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
 * Deliberately no capability ranking across arbitrary model strings. The one real order this
 * file knows — Claude Code's aliases — is used only for an advisory warning.
 *
 * .coding-crew/afk-models.json, the claude-only file this replaces, is moved into
 * `afk.models.claude` the first time `run` sees it. Its values only ever applied on claude, so
 * that is the same behaviour on every platform.
 */
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { PLATFORMS, preflight } from "./dispatch.mjs";

export const CONFIG_REL = ".coding-crew/config.json";
export const USER_CONFIG_LABEL = "~/.coding-crew/config.json";
export const LEGACY_REL = ".coding-crew/afk-models.json";

export const ROLES = ["coder", "reviewer", "triage", "commandFinder", "prdAuditor"];
const SECTIONS = ["afk"];

// The lowest reviewer severity fixed automatically, and what the PRD audit does with its gaps.
export const FIX_FINDINGS = ["critical", "high", "medium", "none"];
export const PRD_AUDIT = ["off", "report", "fix"];
/** Minutes. Every LLM role, plus the merge/close step, which blocks the event loop. */
export const DEFAULT_TIMEOUTS = { coder: 45, reviewer: 20, triage: 20, commandFinder: 5, prdAuditor: 20, merge: 5 };
// setTimeout fires at once past 2^31-1 ms, so a longer timeout would kill every dispatch.
export const MAX_TIMEOUT_MINUTES = Math.floor((2 ** 31 - 1) / 60_000);
const timeoutProblem = (min) =>
  typeof min === "number" && min > 0 && min <= MAX_TIMEOUT_MINUTES
    ? null
    : `must be a positive number of minutes, at most ${MAX_TIMEOUT_MINUTES}`;
export const DEFAULT_SETTINGS = { fixFindings: "high", PRDAudit: "fix", installDeps: true, squashCommits: true };

// Settings that are one value each, merged by replacement; `check` returns a problem or null.
const SCALARS = {
  fixFindings: (v) => (FIX_FINDINGS.includes(v) ? null : `is ${JSON.stringify(v)} (expected ${FIX_FINDINGS.join(", ")})`),
  PRDAudit: (v) => (PRD_AUDIT.includes(v) ? null : `is ${JSON.stringify(v)} (expected ${PRD_AUDIT.join(", ")})`),
  maxParallel: (v) => (Number.isInteger(v) && v > 0 ? null : "must be a positive integer"),
  installDeps: (v) => (typeof v === "boolean" ? null : "must be true or false"),
  squashCommits: (v) => (typeof v === "boolean" ? null : "must be true or false"),
};
const AFK_KEYS = ["runtime", "models", "timeouts", ...Object.keys(SCALARS)];

// afk-models.json's role names, before the plain-dispatch roles were renamed.
const LEGACY_ROLE_NAMES = { commandsDiscovery: "commandFinder", coverageValidation: "prdAuditor" };

// A runtime's model when nothing names one. Resolved here rather than left to the agent file,
// so that an unconfigured sprint's reviewer/triage genuinely match what the coder runs on —
// a default living only in claude.agent.md's frontmatter is invisible to the tier check below.
export const RUNTIME_DEFAULT_MODEL = { claude: "sonnet" };

const CLAUDE_TIER_RANK = { haiku: 0, sonnet: 1, opus: 2 };
const CLAUDE_ALIAS_ENV = {
  haiku: "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  sonnet: "ANTHROPIC_DEFAULT_SONNET_MODEL",
  opus: "ANTHROPIC_DEFAULT_OPUS_MODEL",
};

export class ConfigError extends Error {}

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

function readJson(path, rel) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new ConfigError(`${rel} is not valid JSON (${err.message})`);
  }
}

/** Every problem in one message, so a user fixes the file once rather than once per run. */
export function validateConfig(config, label = CONFIG_REL) {
  const problems = [];
  const oneOf = (list) => list.join(", ");
  if (!isObject(config)) throw new ConfigError(`${label} must be a JSON object`);
  for (const k of Object.keys(config)) {
    if (!SECTIONS.includes(k)) problems.push(`unknown section "${k}" (expected ${oneOf(SECTIONS)})`);
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
      }
      if (afk.timeouts !== undefined) {
        if (!isObject(afk.timeouts)) problems.push(`"afk.timeouts" must be an object of role → minutes`);
        else {
          for (const [k, min] of Object.entries(afk.timeouts)) {
            if (!(k in DEFAULT_TIMEOUTS)) problems.push(`unknown key "afk.timeouts.${k}" (expected ${oneOf(Object.keys(DEFAULT_TIMEOUTS))})`);
            const problem = timeoutProblem(min);
            if (problem) problems.push(`"afk.timeouts.${k}" ${problem}`);
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

/** Every afk leaf a file sets: "runtime.<role>", "models.<runtime>.<role>", "timeouts.<k>", "<scalar>". */
function afkLeaves(afk = {}) {
  const leaves = Object.keys(afk.runtime ?? {}).map((role) => `runtime.${role}`);
  for (const [rt, byRole] of Object.entries(afk.models ?? {})) {
    for (const role of Object.keys(byRole)) leaves.push(`models.${rt}.${role}`);
  }
  for (const k of Object.keys(afk.timeouts ?? {})) leaves.push(`timeouts.${k}`);
  for (const k of Object.keys(SCALARS)) if (afk[k] !== undefined) leaves.push(k);
  return leaves;
}

/** `over` on top of `base`, one setting at a time, so a repo naming one role keeps the rest of yours. */
function mergeAfk(base = {}, over = {}) {
  const runtime = { ...base.runtime, ...over.runtime };
  const timeouts = { ...base.timeouts, ...over.timeouts };
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
    ...scalars,
  };
}

/**
 * Read the repo's config.json, moving a legacy afk-models.json into it. Only `write: true` (a
 * real `run`) touches disk; otherwise the move happens in memory and a notice says it would.
 */
function loadProjectConfig(mainRoot, write, notices) {
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
      if (write) {
        writeFileSync(path, `${JSON.stringify(config, null, 2)}\n`);
        unlinkSync(legacyPath);
        notices.push(`moved ${LEGACY_REL} into ${CONFIG_REL} (afk.models.claude) — commit it.`);
      } else {
        notices.push(`${LEGACY_REL} will be moved into ${CONFIG_REL} (afk.models.claude) on the next \`run\`.`);
      }
    }
  }

  validateConfig(config);
  return config;
}

/**
 * The user's config under the repo's, merged per setting.
 * @returns {{config: object, origin: Record<string, "user"|"project">, notices: string[]}}
 *   origin names which file set each afk leaf ("runtime.reviewer", "models.claude.coder");
 *   throws ConfigError, naming the file, on an invalid one
 */
export function loadConfig(mainRoot, { write = false, home = process.env.HOME || homedir() } = {}) {
  const notices = [];
  // A repo at $HOME (a user-level install's own root) is one file, read once, as the repo's.
  // Read first: an invalid user file must fail the run before the legacy move writes anything.
  const userPath = join(home, CONFIG_REL);
  let user = {};
  if (resolve(userPath) !== resolve(join(mainRoot, CONFIG_REL)) && existsSync(userPath)) {
    user = readJson(userPath, USER_CONFIG_LABEL);
    validateConfig(user, USER_CONFIG_LABEL);
  }
  const project = loadProjectConfig(mainRoot, write, notices);

  const origin = {};
  for (const leaf of afkLeaves(user.afk)) origin[leaf] = "user";
  for (const leaf of afkLeaves(project.afk)) origin[leaf] = "project";
  const config = { ...user, ...project };
  if (user.afk || project.afk) config.afk = mergeAfk(user.afk, project.afk);
  return { config, origin, notices };
}

/**
 * Each role's runtime and model.
 * @returns {{roles: Record<string, {runtime: string, model: string|null}>, warnings: string[]}}
 */
export function resolveCrew({ afk = {}, cliPlatform, cliModel = null }) {
  const warnings = [];
  const models = afk.models ?? {};
  const runtimeOf = (role) => afk.runtime?.[role] ?? cliPlatform;
  const coderRuntime = runtimeOf("coder");

  const onLauncher = (rt) => (rt === cliPlatform ? cliModel : null);
  const coderModel = onLauncher(coderRuntime) ?? models[coderRuntime]?.coder ?? RUNTIME_DEFAULT_MODEL[coderRuntime] ?? null;

  const roles = { coder: { runtime: coderRuntime, model: coderModel } };
  for (const role of ROLES.slice(1)) {
    const runtime = runtimeOf(role);
    const inherited = runtime === coderRuntime ? coderModel : (onLauncher(runtime) ?? RUNTIME_DEFAULT_MODEL[runtime] ?? null);
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

  for (const role of ROLES.slice(1)) {
    const { runtime, model } = roles[role];
    if (
      runtime === "claude" &&
      coderRuntime === "claude" &&
      model !== coderModel &&
      model in CLAUDE_TIER_RANK &&
      coderModel in CLAUDE_TIER_RANK &&
      CLAUDE_TIER_RANK[model] < CLAUDE_TIER_RANK[coderModel]
    ) {
      warnings.push(
        `${role} model "${model}" is a weaker tier than coder model "${coderModel}" — the ` +
          "standard that role holds the branch to may be lower than intended.",
      );
    }
  }
  return { roles, warnings };
}

/** "sonnet (→ <id>, ANTHROPIC_DEFAULT_SONNET_MODEL)" when this process can see the mapping. */
export function describeModel(runtime, model, env = process.env) {
  if (!model) return "runtime default";
  const envName = runtime === "claude" ? CLAUDE_ALIAS_ENV[model] : undefined;
  return envName && env[envName] ? `${model} (→ ${env[envName]}, ${envName})` : model;
}

/** Which agent definition each dispatching role needs installed; the plain-dispatch roles need none. */
export const ROLE_AGENTS = { coder: "crew-coder", reviewer: "crew-reviewer", triage: "crew-triage" };

/** The bash dispatcher a runtime's agent dispatch needs; claude and copilot resolve their agent themselves. */
export const DISPATCHER = { pi: "dispatch-agent.sh", codex: "dispatch-codex-agent.sh" };

/** The roles a run dispatches: the command finder and the PRD audit are each optional. */
export function activeRoles({ commands = true, PRDAudit = DEFAULT_SETTINGS.PRDAudit } = {}) {
  return ROLES.filter((r) => (r !== "commandFinder" || commands) && (r !== "prdAuditor" || PRDAudit !== "off"));
}

// The flag that overrides each setting, for error text.
const FLAG_FOR = {
  fixFindings: "--fix-findings",
  PRDAudit: "--prd-audit",
  maxParallel: "--max-parallel",
  "timeouts.coder": "--coder-timeout",
  "timeouts.reviewer": "--reviewer-timeout",
  "timeouts.merge": "--merge-timeout",
};

/** A bad flag value, checked by the same rules as its config.json setting. */
export function validateFlags(cli = {}, flagOf = {}) {
  const problems = [];
  const name = (k) => flagOf[k] ?? FLAG_FOR[k] ?? "--review-timeout";
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
 * @returns {{fixFindings, PRDAudit, installDeps, squashCommits, maxParallel: number|null,
 *   timeouts: Record<string, number>}}  timeouts in minutes
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
  return {
    fixFindings: pick("fixFindings"),
    PRDAudit: pick("PRDAudit"),
    installDeps: pick("installDeps"),
    squashCommits: pick("squashCommits"),
    maxParallel: pick("maxParallel"),
    timeouts,
  };
}

/**
 * preflight() once per runtime the active roles use, for the agents bound to it, plus the
 * dispatcher of each pi/codex runtime an agent dispatches on — a plain dispatch calls the CLI
 * directly, so a runtime used only by one needs no dispatcher. A problem on a runtime other
 * than the launcher's names its roles, since the user chose that runtime in config.json.
 */
export function crewPreflight(effects, mainRoot, { crew, roles, launcher, paneHost = null, dispatcherDirs = {} }) {
  const byRuntime = new Map();
  for (const role of roles) {
    const { runtime } = crew[role];
    if (!byRuntime.has(runtime)) byRuntime.set(runtime, { roles: [], agents: [] });
    byRuntime.get(runtime).roles.push(role);
    if (ROLE_AGENTS[role]) byRuntime.get(runtime).agents.push(ROLE_AGENTS[role]);
  }
  const problems = [];
  for (const [runtime, { roles: bound, agents }] of byRuntime) {
    const found = preflight(effects, runtime, mainRoot, agents, { paneHost });
    paneHost = null; // checked once, not once per runtime
    if (!process.env.CREW_FAKE_DISPATCH && agents.length && DISPATCHER[runtime] && !dispatcherDirs[runtime]) {
      found.push(`${DISPATCHER[runtime]} not found for ${runtime} — run: ./install.sh ${runtime} --skill crew-afk`);
    }
    const tag = runtime === launcher ? "" : `${bound.join(", ")} → ${runtime}: `;
    problems.push(...found.map((p) => `${tag}${p}`));
  }
  return problems;
}
