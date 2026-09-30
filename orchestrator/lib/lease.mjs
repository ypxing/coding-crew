/**
 * lease.mjs — the feature lease's decisions: acquire, reclaim-or-refuse, release.
 *
 * The git effects are lease.sh's (one compare-and-swap push each); what to do about a lease
 * someone else holds is decided here. Only under `tracker: github` and never for --dry-run.
 */

import { hostname } from "node:os";

const OWNER_RE = /run=(\S+) host=(\S+) pid=(\d+) at=(\S+)/;

export function ownerMessage({ runId, host, pid, at }) {
  return `run=${runId} host=${host} pid=${pid} at=${at}`;
}

export function parseOwner(message) {
  const m = OWNER_RE.exec(message ?? "");
  return m ? { runId: m[1], host: m[2], pid: Number(m[3]), at: m[4] } : null;
}

export function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err?.code === "EPERM";
  }
}

function age(at, now) {
  const ms = now - Date.parse(at);
  if (!Number.isFinite(ms) || ms < 0) return "unknown time";
  const m = Math.floor(ms / 60000);
  if (m < 1) return "under a minute";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h ${m % 60}m` : `${Math.floor(h / 24)}d ${h % 24}h`;
}

export function refusalMessage(slug, owner, raw, now = Date.now()) {
  const who = owner
    ? `run ${owner.runId} on ${owner.host} since ${owner.at} (${age(owner.at, now)} ago)`
    : `an unrecognised owner (${raw || "no message"})`;
  return `crew-afk: feature ${slug} is leased by ${who} — if that run is dead: crew-afk --reclaim`;
}

/** `{ sha, owner: <message> } | null` (no lease), or throws with lease.sh's stderr. */
function readOwner(effects, slug) {
  const r = effects.bash("lease.sh", ["owner", "--slug", slug], { mutating: false });
  if (r.code !== 0) throw new Error(r.stderr.trim() || `lease.sh owner exited ${r.code}`);
  const lines = r.stdout.split("\n");
  const sha = lines.find((l) => l.startsWith("SHA "))?.slice(4).trim();
  if (!sha) return null;
  return { sha, message: (lines.find((l) => l.startsWith("OWNER ")) ?? "").slice(6).trim() };
}

function write(effects, verb, slug, message, expect) {
  const args = [verb, "--slug", slug, "--owner", message, ...(expect ? ["--expect", expect] : [])];
  const r = effects.bash("lease.sh", args);
  const sha = /^SHA (\S+)/m.exec(r.stdout)?.[1];
  return { code: r.code, sha, stderr: r.stderr.trim() };
}

/**
 * Acquire the lease for `slug`. Returns `{ lease: { slug, sha } }` or `{ error }` (the run must stop).
 * A dead pid on this host is reclaimed automatically; anything else needs `reclaim`.
 */
export function acquireLease(effects, { slug, runId, reclaim = false, log = () => {}, host = hostname(), pid = process.pid, now = () => Date.now(), pidAlive = isPidAlive }) {
  const message = ownerMessage({ runId, host, pid, at: new Date(now()).toISOString() });
  const failure = (what, detail) => ({ error: `crew-afk: could not ${what} the feature lease refs/crew-lock/${slug} on origin: ${detail}` });
  try {
    for (let pass = 0; pass < 2; pass++) {
      const held = readOwner(effects, slug);
      if (!held) {
        const w = write(effects, "acquire", slug, message, "");
        if (w.code === 0) return { lease: { slug, sha: w.sha } };
        if (w.code !== 3) return failure("acquire", w.stderr);
        continue; // lost a create race: read who won
      }
      const owner = parseOwner(held.message);
      const deadHere = owner && owner.host === host && !pidAlive(owner.pid);
      if (pass === 0 && (reclaim || deadHere)) {
        const w = write(effects, "reclaim", slug, message, held.sha);
        if (w.code === 0) {
          log(`LEASE: reclaimed ${slug} from ${owner ? `run ${owner.runId} on ${owner.host} (pid ${owner.pid}${deadHere ? ", dead" : ""})` : "an unrecognised owner"}${reclaim ? " (--reclaim)" : ""}`);
          return { lease: { slug, sha: w.sha } };
        }
        if (w.code !== 3) return failure("reclaim", w.stderr);
        continue; // another reclaimer won this SHA: report them, never take theirs
      }
      return { error: refusalMessage(slug, owner, held.message, now()) };
    }
    return { error: `crew-afk: feature ${slug}'s lease keeps changing hands — another run is starting; re-run in a moment.` };
  } catch (err) {
    return failure("acquire", err.message);
  }
}

/**
 * Release with a CAS on our own SHA. Never throws, never deletes a lease another run now owns.
 * Returns `{ released: true }`, `{ superseded: true }` or `{ failed: <reason>, command }`.
 */
export function releaseLease(effects, lease) {
  if (!lease || lease.released) return { released: true };
  const command = `git push origin :refs/crew-lock/${lease.slug}`;
  try {
    const r = effects.bash("lease.sh", ["release", "--slug", lease.slug, "--expect", lease.sha]);
    if (r.code === 0) {
      lease.released = true;
      return { released: true };
    }
    if (r.code === 3) {
      lease.released = true;
      return { superseded: true };
    }
    return { failed: r.stderr.trim() || `lease.sh exited ${r.code}`, command };
  } catch (err) {
    return { failed: err.message, command };
  }
}
