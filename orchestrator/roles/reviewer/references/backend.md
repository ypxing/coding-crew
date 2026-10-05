# Reference — Backend / Service Patterns (HIGH)

Loaded only when the repo declares a server framework or database client (Node, Python, Go, Ruby).

- **Unvalidated input** — request body/params used without schema validation at trust boundaries
- **Missing rate limiting** — public endpoints without throttling
- **Unbounded queries** — `SELECT *` or queries without LIMIT on user-facing endpoints
- **Missing timeouts** — external HTTP calls without timeout configuration
- **Error message leakage** — sending internal error details to clients
- **Missing CORS configuration** — APIs accessible from unintended origins
- **N+1 queries** — a per-row query inside a loop over a user-sized collection

Validation and rate limiting are frequently applied one frame up (middleware, a router-level
guard, an API gateway). Trace at least one caller and the middleware chain before flagging either.
