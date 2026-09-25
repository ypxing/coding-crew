# Reference — Web Security (OWASP, HTTP-surface specific)

Loaded when the repo has a web or HTTP surface (browser code, templates, or a server framework).
These extend — not replace — the always-on CRITICAL classes in the protocol (hardcoded
credentials, injection, path traversal, auth bypass, broken access control, sensitive data
exposure, insecure dependencies).

Flag these when found **in the diff**:

- **XSS** — unescaped user input rendered in HTML/JSX; missing CSP; `innerHTML = userInput`
- **CSRF** — state-changing endpoints without CSRF protection
- **SSRF** — `fetch(userProvidedUrl)` or equivalent without a domain whitelist
- **Insecure deserialization** — user input passed directly to `JSON.parse`, `eval`,
  `unserialize`, or object constructors
- **XXE** — XML parsers without external entity resolution disabled
- **Security misconfiguration** — debug mode on, default credentials, missing security headers
- **CORS misconfiguration** — `*` origin with credentials, or reflected `Origin` without an
  allowlist (the web half of broken access control)
- **Token validation** — JWT signature/expiry not verified; session fixation; passwords compared
  in plaintext instead of `bcrypt.compare()` or equivalent
- **Missing transaction lock** — balance/inventory checks without `FOR UPDATE` or an equivalent
  guard, reachable from a concurrent HTTP request

Cross-reference the dependency audit output when flagging a vulnerable package: a CRITICAL that
names a CVE the audit did not report needs the failure path spelled out.
