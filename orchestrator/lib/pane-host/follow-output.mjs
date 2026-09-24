#!/usr/bin/env node
/**
 * What a worker terminal shows (worker-terminal.mjs): follows the child's output file until
 * its rc file lands. A JSON event stream is shown as the same `[TOOL]` lines the trace log
 * gets, plus claude's assistant text; anything else is shown as-is. Display only — the
 * child never writes through this process, so it can fail without touching the dispatch.
 *
 *   follow-output.mjs <out> <rc> [<jsonEvents platform>] [<agent>]
 */

import { closeSync, existsSync, openSync, readSync } from "node:fs";
import { formatJsonTraceLine } from "../dispatch.mjs";

const [out, rc, platform = "", agent = ""] = process.argv.slice(2);
const buf = Buffer.alloc(64 * 1024);
let fd = null;
let offset = 0;
let partial = "";

function show(line) {
  if (!platform) return console.log(line);
  const trace = formatJsonTraceLine(platform, agent, line);
  if (trace) return console.log(trace);
  if (platform !== "claude") return;
  try {
    const evt = JSON.parse(line);
    if (evt.type !== "assistant") return;
    for (const block of evt.message?.content ?? []) {
      if (block.type === "text" && block.text.trim()) console.log(block.text.trim());
    }
  } catch {
    /* not an event */
  }
}

function drain() {
  if (fd === null) {
    if (!existsSync(out)) return;
    fd = openSync(out, "r");
  }
  for (;;) {
    const n = readSync(fd, buf, 0, buf.length, offset);
    if (n <= 0) return;
    offset += n;
    const parts = (partial + buf.toString("utf8", 0, n)).split("\n");
    partial = parts.pop();
    for (const line of parts) if (line.trim()) show(line);
  }
}

for (;;) {
  const done = existsSync(rc);
  drain();
  if (done) break;
  await new Promise((r) => setTimeout(r, 250));
}
if (partial.trim()) show(partial);
if (fd !== null) closeSync(fd);
