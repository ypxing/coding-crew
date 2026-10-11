#!/usr/bin/env node
/**
 * What a worker terminal shows: follows one of the child's output files until its rc file lands, a
 * JSON event stream as `[TOOL]` lines. Display only, so it can fail without touching the dispatch.
 *
 *   follow-output.mjs <out> <rc> [<jsonEvents platform>] [<agent>]
 */

import { closeSync, existsSync, openSync, readSync } from "node:fs";
import { ADAPTERS, normalizeLine } from "../adapters/index.mjs";
import { formatTrace } from "../adapters/trace.mjs";

const [out, rc, platform = "", agent = ""] = process.argv.slice(2);
const buf = Buffer.alloc(64 * 1024);
let fd = null;
let offset = 0;
let partial = "";

function show(line) {
  if (!platform) return console.log(line);
  const evt = normalizeLine(platform, line);
  const trace = formatTrace(agent, evt);
  if (trace) return console.log(trace);
  if (evt?.kind === "text" && ADAPTERS[platform]?.liveText) console.log(evt.detail);
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
