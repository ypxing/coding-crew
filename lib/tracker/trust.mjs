/**
 * trust.mjs — the one decision on whose GitHub comments reach an agent: Copilot's reviewer, the
 * identity the agent posts as, or a user with write, maintain or admin permission on the repo.
 * Everyone else's comments are dropped before any agent reads them.
 */

const COPILOT_REVIEWER = "copilot-pull-request-reviewer";
const WRITE_ROLES = new Set(["write", "maintain", "admin"]);

/** REST names a bot `<name>[bot]`, GraphQL `<name>`: compare without the suffix. */
const bare = (login) => String(login ?? "").replace(/\[bot\]$/, "");

/**
 * `(login) => boolean` for one invocation, each login decided once. `repo` is `owner/name`, or
 * null for the current directory's repo. A failed permission call (a non-collaborator's 404, the
 * network, a rate limit) is untrusted: an unattended run cannot ask, and a dropped trusted comment
 * only costs a later round.
 */
export function trustChecker({ exec, repo = null, env = process.env }) {
  const cache = new Map();
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
    if (cache.has(key)) return cache.get(key);
    let trusted = key === COPILOT_REVIEWER || key === postingIdentity();
    if (!trusted) {
      const r = exec("gh", ["api", `${prefix}/collaborators/${encodeURIComponent(login)}/permission`, "--jq", ".permission, .role_name"]);
      trusted = r.code === 0 && r.stdout.split("\n").some((l) => WRITE_ROLES.has(l.trim()));
    }
    cache.set(key, trusted);
    return trusted;
  };
}

/** The line that stands in for dropped comments: `count` of them, by `authors` (a deleted account's empty login is `ghost`, as GitHub shows it). */
export function omittedLine({ count, authors }) {
  return `(omitted ${count} comment(s) by ${authors.map((a) => `@${a || "ghost"}`).join(", ")}: no write access to this repo)`;
}
