/**
 * trust.mjs — the one decision on whose GitHub comments reach an agent: Copilot's reviewer, the
 * identity the agent posts as, a bot the repo lists under `github.trustedBots` in its config.json, or
 * a user with write, maintain or admin permission on the repo.
 * Everyone else's comments are dropped before any agent reads them.
 */

import { join } from "node:path";

import { CONFIG_REL_PATH, isObject, readConfigFile } from "./tracker-config.mjs";

const COPILOT_REVIEWER = "copilot-pull-request-reviewer";
/** The identity an Actions workflow token posts as: a Bot, whose bare login is free for any user to take. */
const ACTIONS_BOT = "github-actions";
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

/** `nodes` takes at most 100 ids a call. */
const NODES_PAGE = 100;

/**
 * The ids, of `ids`, whose comment GitHub says a Bot wrote. `gh issue view`/`gh pr view` name an author by
 * bare login only, which a user can also hold; `__typename` tells the two apart. gh exits non-zero when any id
 * no longer resolves (a deleted comment) yet prints the other nodes, so only what it cannot report counts none.
 */
function botWritten(exec, ids) {
  const bots = new Set();
  for (let i = 0; i < ids.length; i += NODES_PAGE) {
    const query = `query { nodes(ids: ${JSON.stringify(ids.slice(i, i + NODES_PAGE))}) { ... on Comment { id author { __typename } } } }`;
    const r = exec("gh", ["api", "graphql", "-f", `query=${query}`]);
    let nodes = [];
    try {
      nodes = JSON.parse(r.stdout || "{}").data?.nodes ?? [];
    } catch {}
    for (const n of nodes) if (n?.author?.__typename === "Bot") bots.add(n.id);
  }
  return bots;
}

/**
 * `(comments) => Set` for one invocation: of `comments` (`{author, id}`, `id` the comment's node id), those
 * to keep, each login decided once. `repo` is `owner/name`, or null for the current directory's repo. A
 * failed permission call (a non-collaborator's 404, the network, a rate limit) is untrusted: an unattended
 * run cannot ask, and a dropped trusted comment only costs a later round. A listed bot's comment, and on
 * Actions the workflow token's, is kept with no permission call when GitHub says a Bot wrote it. `mainRoot`'s `github.trustedBots` applies only
 * to its own repo, and only while `gh repo view` reports it private or internal: on a public repo anyone
 * can make a bot quote their text. With a named `repo`, only when `gh repo view` names the same one
 * (GitHub compares case-insensitively).
 */
export function trustChecker({ exec, repo = null, mainRoot = null, env = process.env }) {
  const cache = new Map();
  const listed = trustedBots(mainRoot);
  let listApplies;
  const applies = () => {
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
      self = login ? { login: bare(login), bot: false } : env.GITHUB_ACTIONS === "true" ? { login: ACTIONS_BOT, bot: true } : null;
    }
    return self;
  };
  const isSelf = (key, bot) => postingIdentity()?.login === key && postingIdentity().bot === bot;
  // Names a Bot holds but a user could also take: trusted only for a comment GitHub says a Bot wrote.
  const botName = (key) => (listed.includes(key) && applies()) || (key === ACTIONS_BOT && isSelf(key, true));
  const prefix = repo ? `repos/${repo}` : "repos/{owner}/{repo}";
  const byLogin = (login) => {
    const key = bare(login);
    if (!key) return false;
    if (cache.has(key)) return cache.get(key);
    let trusted = key === COPILOT_REVIEWER || isSelf(key, false);
    if (!trusted) {
      const r = exec("gh", ["api", `${prefix}/collaborators/${encodeURIComponent(login)}/permission`, "--jq", ".permission, .role_name"]);
      trusted = r.code === 0 && r.stdout.split("\n").some((l) => WRITE_ROLES.has(l.trim()));
    }
    cache.set(key, trusted);
    return trusted;
  };
  return (comments) => {
    const asBot = comments.filter((c) => c.id && botName(bare(c.author)));
    const bots = asBot.length ? botWritten(exec, [...new Set(asBot.map((c) => c.id))]) : new Set();
    return new Set(comments.filter((c) => (asBot.includes(c) && bots.has(c.id)) || byLogin(c.author)));
  };
}

/** The line that stands in for dropped comments: `count` of them, by `authors` (a deleted account's empty login is `ghost`, as GitHub shows it). */
export function omittedLine({ count, authors }) {
  return `(omitted ${count} comment(s) by ${authors.map((a) => `@${a || "ghost"}`).join(", ")}: no write access to this repo)`;
}
