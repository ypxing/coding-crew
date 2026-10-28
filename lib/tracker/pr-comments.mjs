#!/usr/bin/env node
/**
 * pr-comments.mjs — one PR's reviews, top-level comments and review threads as JSON, with every
 * comment by an author trustChecker does not trust removed before an agent reads it; the main checkout's
 * `github.trustedBots` (config.json) is read from a linked worktree too.
 *   node <skill-dir>/../coding-crew-lib/scripts/tracker/pr-comments.mjs <pr-number | pr-url>
 * Prints `{reviews, comments, threads, omitted}`; a thread is `{id, url, path, line, isResolved,
 * comments}`, and one left with no comment is omitted. `omitted` is `{count, authors}`, plus `line`
 * when anything was dropped. Exit 0 ok, 1 a `gh` read failed, 2 a usage error.
 */

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { gh } from "./github.mjs";
import { mainCheckout } from "./tracker-config.mjs";
import { omittedLine, trustChecker } from "./trust.mjs";

class UsageError extends Error {}

const USAGE = "usage: pr-comments.mjs <pr-number | pr-url>";
const PR_URL = /^https:\/\/github\.com\/([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+)\/pull\/([0-9]+)(?:[/?#].*)?$/;

const THREADS_QUERY = `query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved path line
          comments(first: 100) { nodes { id author { login } body createdAt url } }
        }
      }
    }
  }
}`;

/** `{repo, number}` from the argument; `repo` null for the current directory's repo. */
function parseTarget(argv) {
  if (argv.length !== 1) throw new UsageError(USAGE);
  const [arg] = argv;
  if (/^[0-9]+$/.test(arg)) return { repo: null, number: arg };
  const m = PR_URL.exec(arg);
  if (!m) throw new UsageError(`${USAGE} — not a PR number or github.com PR URL: ${arg}`);
  return { repo: `${m[1]}/${m[2]}`, number: m[3] };
}

function ghJson(exec, args) {
  const r = exec("gh", args);
  if (r.code !== 0) throw new Error(`gh ${args.slice(0, 2).join(" ")} failed (exit ${r.code}): ${r.stderr || r.stdout}`);
  return JSON.parse(r.stdout || "{}");
}

const comment = (c) => ({ author: c.author?.login ?? "", body: c.body ?? "", createdAt: c.createdAt ?? "", url: c.url ?? "" });

function readThreads(exec, { repo, number }) {
  const [owner, name] = repo ? repo.split("/") : ["{owner}", "{repo}"];
  const threads = [];
  let after = null;
  do {
    // -F fills the {owner}/{repo} placeholders; a named repo's go as raw strings, as -F reads an all-digit owner as a number.
    const str = repo ? "-f" : "-F";
    const args = ["api", "graphql", str, `owner=${owner}`, str, `name=${name}`, "-F", `number=${number}`];
    if (after) args.push("-F", `after=${after}`);
    args.push("-f", `query=${THREADS_QUERY}`);
    const page = ghJson(exec, args).data?.repository?.pullRequest?.reviewThreads;
    if (!page) throw new Error(`gh api graphql: no reviewThreads for PR ${number}`);
    threads.push(...(page.nodes ?? []));
    after = page.pageInfo?.hasNextPage ? page.pageInfo.endCursor : null;
  } while (after);
  return threads;
}

/** The PR's comments, untrusted authors' removed. */
export function prComments(exec, target, { mainRoot = null } = {}) {
  const repoArgs = target.repo ? ["--repo", target.repo] : [];
  const view = ghJson(exec, ["pr", "view", target.number, ...repoArgs, "--json", "reviews,comments"]);
  const rawThreads = readThreads(exec, target);
  // Each comment is decided with its node id, which the output leaves out.
  const entry = (raw, out) => ({ author: out.author, id: raw.id ?? "", out });
  const reviews = (view.reviews ?? []).map((r) => entry(r, { author: r.author?.login ?? "", body: r.body ?? "", state: r.state ?? "", submittedAt: r.submittedAt ?? "" }));
  const comments = (view.comments ?? []).map((c) => entry(c, comment(c)));
  const threads = rawThreads.map((t) => ({ t, all: (t.comments?.nodes ?? []).map((c) => entry(c, comment(c))) }));
  const trusted = trustChecker({ exec, repo: target.repo, mainRoot })([...reviews, ...comments, ...threads.flatMap((t) => t.all)]);
  const dropped = [];
  const keep = (e) => {
    if (trusted.has(e)) return true;
    // GitHub opens an empty-body review for each inline comment: it carries no text to omit.
    if (e.out.body !== "") dropped.push(e.author);
    return false;
  };
  const kept = (entries) => entries.filter(keep).map((e) => e.out);

  const out = {
    reviews: kept(reviews),
    comments: kept(comments),
    threads: threads
      .map(({ t, all }) => ({ id: t.id, url: all[0]?.out.url ?? "", path: t.path ?? null, line: t.line ?? null, isResolved: Boolean(t.isResolved), comments: kept(all) }))
      .filter((t) => t.comments.length > 0),
  };

  const omitted = { count: dropped.length, authors: [...new Set(dropped)] };
  if (omitted.count) omitted.line = omittedLine(omitted);
  return { ...out, omitted };
}

/** Run with `argv`; resolves to the exit code. `io` (`exec`, `cwd`, `out`, `err`) is injectable for tests. */
export async function run(argv, io = {}) {
  const exec = io.exec ?? gh;
  const cwd = io.cwd ?? process.cwd();
  const out = io.out ?? ((s) => process.stdout.write(s));
  const err = io.err ?? ((s) => process.stderr.write(s));
  try {
    const target = parseTarget(argv);
    out(`${JSON.stringify(prComments(exec, target, { mainRoot: mainCheckout(cwd) }), null, 2)}\n`);
    return 0;
  } catch (e) {
    err(`${e.message}\n`);
    return e instanceof UsageError ? 2 : 1;
  }
}

function invokedDirectly() {
  try {
    return Boolean(process.argv[1]) && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  process.exitCode = await run(process.argv.slice(2));
}
