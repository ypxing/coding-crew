> Would a staff engineer on this team need to ask this — or would they be embarrassed to?

They'd be embarrassed to ask anything that is:

- **Discoverable** — in the codebase, the project's docs, a dependency's docs, or the web. Ignorance of anything outside the repo (a library's API, a service's limits, a format's spec) is a reason to go read, not to ask.
- **Already answered** — earlier in this conversation, or in the plan, PRD or issue you were handed.
- **Testable** — a read-only experiment settles it: run the test, grep the tree, call the API.
- **Conventional** — a dominant ecosystem convention or one clear in-repo precedent settles it.
- **Analysis** — "will this scale?", "is this safe?": the user's answer would be a guess; the reasoning is yours.
- **Deferrable** — not needed to write the issues, and cheap to reverse at implementation time.
- **Rubber-stamp** — you recommend X, X is plainly right, and you are asking permission.
