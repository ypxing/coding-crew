/**
 * trust.mjs — the one decision on whose GitHub comments reach an agent: Copilot's reviewer, the
 * identity the agent posts as, a bot the repo lists under `github.trustedBots` in its config.json, or
 * a user with write, maintain or admin permission on the repo.
 * Everyone else's comments are dropped before any agent reads them.
 */

import { join } from "node:path";

import { CONFIG_REL_PATH, isObject, readConfigFile } from "./tracker-config.mjs";

const COPILOT_REVIEWER = "copilot-pull-request-reviewer";
const WRITE_ROLES = new Set(["write", "maintain", "admin"]);

/** REST names a bot `<name>[bot]`, GraphQL `<name>`: compare without the suffix. */
const bare = (login) => String(login ?? "").replace(/\[bot\]$/, "");

/**
 * The project's `github.trustedBots`, bare logins; empty when the file, section or key is absent. Never the
 * user-level config: a bot's login is per org, and the Actions runner sees only the project's file.
 */
function trustedBots(mainRoot) {
  if (!mainRoot) return [];
  const path = join(mainRoot, CONFIG_REL_PATH);
  const github = readConfigFile(path)?.github;
  if (github === undefined) return [];
  const bots = !isObject(github) ? null : github.trustedBots === undefined ? [] : github.trustedBots;
  if (!Array.isArray(bots) || !bots.every((b) => typeof b === "string" && b.trim() !== "")) {
    throw new Error(`${path}: "github" must be an object whose "trustedBots" is an array of non-empty bot logins, as in {"github": {"trustedBots": ["<bot login>"]}}`);
  }
  return bots.map((b) => bare(b.trim()));
}

/**
 * `(login) => boolean` for one invocation, each login decided once. `repo` is `owner/name`, or
 * null for the current directory's repo. A failed permission call (a non-collaborator's 404, the
 * network, a rate limit) is untrusted: an unattended run cannot ask, and a dropped trusted comment
 * only costs a later round. `mainRoot`'s `github.trustedBots` applies only to its own repo, and only while
 * `gh repo view` reports it private or internal: on a public repo anyone can make a bot quote their text.
 * With a named `repo`, only when `gh repo view` names the same one (GitHub compares case-insensitively).
 */
export function trustChecker({ exec, repo = null, mainRoot = null, env = process.env }) {
  const cache = new Map();
  const listed = trustedBots(mainRoot);
  let listApplies;
  const isListedBot = (key) => {
    if (!listed.includes(key)) return false;
    if (listApplies === undefined) {
      const r = exec("gh", ["repo", "view", "--json", "nameWithOwner,visibility", "--jq", '.nameWithOwner + " " + .visibility']);
      const [name, visibility] = r.stdout.trim().split(" ");
      listApplies = r.code === 0 && (repo === null || name.toLowerCase() === repo.toLowerCase()) && ["PRIVATE", "INTERNAL"].includes(visibility);
    }
    return listApplies;
  };
  let self;
  const postingIdentity = () => {
    if (self === undefined) {
      const r = exec("gh", ["api", "user", "--jq", ".login"]);
      const login = r.code === 0 ? r.stdout.trim() : "";
      // The Actions workflow token cannot read /user.
      self = login ? bare(login) : env.GITHUB_ACTIONS === "true" ? "github-actions" : null;
    }
    return self;
  };
  const prefix = repo ? `repos/${repo}` : "repos/{owner}/{repo}";
  return (login) => {
    const key = bare(login);
    if (!key) return false;
    if (cache.has(login)) return cache.get(login);
    let trusted = key === COPILOT_REVIEWER || isListedBot(key) || key === postingIdentity();
    if (!trusted) {
      const r = exec("gh", ["api", `${prefix}/collaborators/${encodeURIComponent(login)}/permission`, "--jq", ".permission, .role_name"]);
      trusted = r.code === 0 && r.stdout.split("\n").some((l) => WRITE_ROLES.has(l.trim()));
    }
    cache.set(login, trusted);
    return trusted;
  };
}

/** The line that stands in for dropped comments: `count` of them, by `authors` (a deleted account's empty login is `ghost`, as GitHub shows it). */
export function omittedLine({ count, authors }) {
  return `(omitted ${count} comment(s) by ${authors.map((a) => `@${a || "ghost"}`).join(", ")}: no write access to this repo)`;
}
