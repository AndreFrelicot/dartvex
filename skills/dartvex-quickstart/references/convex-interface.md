# The Convex interface, as consumed from Dart

The minimum Convex semantics needed to use dartvex. For *authoring* backends
(schema, validators, indexes, cron), use the official Convex skills
(`npx skills add convex/agent-skills`) or https://docs.convex.dev.

## Deployments and URLs

A Convex backend is a *deployment* reachable at
`https://<name>.convex.cloud`. dartvex talks to it over a WebSocket sync
protocol (the one the official JS client uses; Dartvex 0.3.0 tracks
`convex` 1.49.0, see `convexSyncApiVersion`). The URL identifies the
environment (dev/prod are separate deployments) — treat it like
configuration, not code.

## Functions and paths

The backend exposes three kinds of functions, referenced by string path
`file:function` (nested: `dir/file:function`):

| Kind | Semantics | dartvex call |
|------|-----------|--------------|
| query | Read-only, deterministic, *reactive* — the server pushes updates to subscribers | `client.query`, `client.queryOnce<T>`, `client.subscribe` |
| mutation | Transactional write | `client.mutate` |
| action | Side-effecting (can call external APIs); not transactional, not reactive | `client.action` |

Arguments are always a single JSON-like map (`Map<String, dynamic>`). A
function declared with no args takes `{}`.

## Type mapping (Convex validator ⇄ Dart)

| Convex | Dart (decode) | Dart (encode args) |
|--------|---------------|--------------------|
| `v.string()` | `String` | `String` |
| `v.number()` (float64) | `num` — `int` for integral values, else `double` (generated bindings always use `double`) | `int` or `double` (an `int` beyond ±2^53 that a float64 cannot hold throws) |
| `v.int64()` | `BigInt` | `convexInt64(n)` or `BigInt` |
| `v.commitTs()` (convex 1.43+) | `BigInt`; an unresolved `{"$commitTs": null}` placeholder (a mutation returning a field it just wrote) decodes to `ConvexCommitTsPlaceholder.instance` — generated bindings type it `Object` | — |
| `v.boolean()` | `bool` | `bool` |
| `v.null()` | `null` | `null` |
| `v.bytes()` | `Uint8List` | `Uint8List` |
| `v.array(...)` | `List<dynamic>` | `List` |
| `v.object({...})` | `Map<String, dynamic>` | `Map<String, dynamic>` |
| `v.id("table")` | `String` (document ID) | `String` |
| `v.function()` | `String` (function handle) | `String` |

Special encodings (`$integer`, `$float`, `$bytes`, `$commitTs`) are handled
by dartvex automatically. Do not build them by hand.

Documents returned by queries carry system fields `_id` (string ID) and
`_creationTime` (float64 milliseconds).

## Reactivity model

A *subscription* to a query receives a new result every time any data the
query read changes — push-based, no polling. dartvex keeps the query set
alive across reconnects and replays it, so subscriptions survive network
drops. Mutations are read-your-writes: after `await client.mutate(...)`,
subsequent reads reflect the write.

## Pagination contract

A paginated Convex query takes a `paginationOpts` argument
(`{numItems, cursor}`) and returns
`{page: [...], isDone: bool, continueCursor: String}`. dartvex drives this
protocol for you via `client.paginatedQuery(...)` (core) or
`PaginatedQueryBuilder` (Flutter) — never assemble `paginationOpts` manually
unless you are doing something unusual.

## Auth contract

The client authenticates the WebSocket by sending an OpenID Connect JWT
(obtained from any auth provider the backend trusts). On the backend,
`ctx.auth.getUserIdentity()` exposes the verified identity. dartvex handles
delivery, refresh scheduling, and re-auth on reconnect — you supply the
token via `client.setAuth(...)`, `client.setAuthWithRefresh(...)`, or an
`AuthProvider` adapter such as `dartvex_auth_better`. A deployment can also
mint its own short-lived JWTs in a mutation (`ctx.auth.signJwt`); see the
`dartvex-setup-auth` skill.

## Errors

A failed function call carries a human-readable `message`, optional
structured `data` (from `ConvexError` on the backend), and server `logLines`.
dartvex surfaces these on `QueryError` results and `ConvexException`.
