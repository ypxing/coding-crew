# Reference — React / Next.js Patterns (HIGH)

Loaded only when the repo declares `react` or `next` (or ships `.jsx`/`.tsx` files).

- **Missing dependency arrays** — `useEffect`/`useMemo`/`useCallback` with incomplete deps
- **State updates in render** — calling setState during render causes infinite loops
- **Missing keys in lists** — using array index as key when items can reorder
- **Prop drilling** — props passed through 3+ levels (use context or composition)
- **Client/server boundary** — using `useState`/`useEffect` in Server Components
- **Missing loading/error states** — data fetching without fallback UI
- **Stale closures** — event handlers capturing stale state values

Before flagging any of these, trace the actual render path. A `useEffect` with an intentionally
empty dep array and a comment saying so is not a finding; a `key={index}` on a list that is never
reordered or filtered is a LOW at most.
