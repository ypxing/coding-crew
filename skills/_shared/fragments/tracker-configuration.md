## Tracker Configuration

Every tracker operation in this skill is an op of the tracker CLI — nothing else reads or writes
the tracker. Before the first one, check for Node:

```bash
node --version
```

If that fails, stop and tell the user: "the tracker CLI needs Node — install Node, then re-run this
skill." Otherwise locate the CLI once — this prints its absolute path:

```bash
TRACKER="$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs"
[ -f "$TRACKER" ] || TRACKER="$HOME/.coding-crew/tracker/cli.mjs"   # user-level install
echo "$TRACKER"
```

Each shell command runs in a fresh shell, so `$TRACKER` is gone by the next one. Wherever this skill
runs an op as `node "$TRACKER" <op> …`, write the absolute path it printed in place of `$TRACKER`:

```bash
node "$TRACKER" <op> …   # run as: node "/abs/path/printed/above/cli.mjs" <op> …
```

The tracker it talks to is set in `$(git rev-parse --show-toplevel)/.coding-crew/docs/issue-tracker.md`;
if that file does not exist, invoke the `configure-tracker` skill now to set it up, then continue.

Exit codes, every op: 0 ok; 1 the op failed — stderr carries the tracker's own error, verbatim;
2 a usage error or an invalid ref; 3 not found. On 1 or 2, report the stderr to the user and
fix its cause (an input, auth, the network), then re-run the op —
never perform the operation with the tracker's own tool instead.
