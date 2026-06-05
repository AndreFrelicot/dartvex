# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-04

### Added

- `QuerySuccess` now carries successful query log lines and whether optimistic
  writes are currently affecting the emitted value, so runtime adapters can
  surface pending-write state from the real client.
- Rich connection status: `ConvexClient.currentConnectionStatus` and the
  `connectionStatus` stream expose a `ConnectionStatus` snapshot
  (`isWebSocketConnected`, `isConnected`, `hasEverConnected`, `connectionCount`,
  `connectionRetries`, `inflightMutations`, `inflightActions`,
  `timeOfOldestInflightRequest`, `hasSyncedPastLastReconnect`, plus derived
  `hasInflightRequests` and `isLoading`). The coarse `ConnectionState` enum and
  its `connectionState` stream are unchanged and remain available as a derived
  convenience. A `ConnectionStatus.fromState` factory derives a best-effort
  snapshot from a coarse state alone. Mirrors the official client's
  `connectionState()`.
- Reactive pagination: `ConvexClient.paginatedQuery(name, args, {pageSize})`
  returns a `ConvexPaginatedQuery` that loads the first page immediately and
  exposes the gapless concatenation of every loaded page as a reactive stream,
  with a `ConvexPaginationStatus`, an `isDone` flag, and `loadMore()`. Each page
  is an ordinary query subscription, so loaded pages update reactively and stay
  gapless across reconnects via the query journals; oversized pages are
  transparently re-split. Mirrors the official client's paginated query engine.
- Optimistic updates: pass an `OptimisticUpdate` to `ConvexClient.mutate` to
  locally overlay query results the instant a mutation is sent. The overlay is
  replayed whenever fresh server data arrives while the mutation is pending and
  rolled back automatically when it completes (replaced by the authoritative
  result without flicker) or fails. Read and edit results through the exported
  `OptimisticLocalStore` (`getQuery` / `getAllQueries` / `setQuery`, with a
  string path, args map, and `dynamic` values). Mirrors the official client's
  optimistic update model.
- `ConvexClientConfig.connectTimeout` bounds the WebSocket handshake so a dead
  connection no longer hangs on the platform TCP timeout before retrying.
- Exponential reconnect backoff with jitter and server-reason classification,
  configurable via `initialBackoff`, `maxBackoff`, and `backoffJitter`.
- `ConnectivitySignal` and `ConvexClientConfig.connectivitySignal` to reconnect
  immediately when the device regains network connectivity, cancelling any
  in-progress backoff.
- Internal post-reconnect sync tracking (`hasSyncedPastLastReconnect`) across
  the local sync state, request manager, and base client: the client now knows
  when every query, auth update, and request issued before a reconnect has been
  confirmed by the server. This is package-internal groundwork for upcoming
  backoff-reset and auth-gating work and is not part of the public API.
- `ConnectionState.fatalError`, a terminal connection state entered when the
  server reports an unrecoverable error.
- `ConvexClientConfig.refreshTokenLeewaySeconds` (default `2`) controls how
  early a token is proactively refreshed before it expires.
- `ConvexClient.authRefreshing` (a `Stream<bool>`) and `isAuthRefreshing`
  report when the client is recovering auth after a server rejection — `true`
  while the socket is stopped and a fresh token is fetched, `false` once it is
  confirmed. Use it to show an "authenticating…" indicator without surfacing the
  brief disconnect. Mirrors the official client's `AuthRefreshing` signal.
- Protocol-level support for `Admin` auth with optional user impersonation
  (`LocalSyncState.setAdminAuth`), including replay across reconnects. This is
  wire-completeness groundwork only — there is intentionally no client-facing
  admin API, since shipping an admin key in an app is a security hazard.
- Exported `WebSocketAdapter`, `WebSocketCloseEvent`, and
  `WebSocketAdapterFactory`, so the existing `ConvexClientConfig.adapterFactory`
  customization point can be supplied with a custom transport implementation.

### Changed

- Auth updates now gate the socket so requests can no longer be sent with
  absent or stale auth: the initial token fetch pauses the socket (buffering
  query-set changes and mutations, replayed together once the token is applied),
  and a reauth triggered by an `AuthError` stops the socket, fetches a fresh
  token, and restarts so it is replayed on a clean connection. Mirrors the
  official client's pause/resume and stop/restart auth gating.
- Auth token refresh is now scheduled from the token's own lifetime
  (`exp - iat`) minus `refreshTokenLeewaySeconds`, instead of from the device
  wall clock (`exp - now - 60`). Refresh timing is now immune to device clock
  skew; tokens without an `iat` claim fall back to the wall clock, and the
  delay is capped at 20 days.

- `reconnectBackoff` now defaults to empty, selecting the exponential backoff
  model. Provide an explicit non-negative schedule to keep fixed delays.
- `Connect.clientTs` and transition transit metrics now read from a monotonic
  clock (a one-time wall-clock anchor plus a monotonic `Stopwatch`) instead of
  `DateTime.now()`, so elapsed-time and server clock-skew estimates stay stable
  even when the device wall clock is corrected.

### Fixed

- `AuthLoading` documentation now matches the emitted auth states: it covers
  login/cache restore, while background token refreshes remain exposed via
  `authRefreshing`.
- `timeOfOldestInflightRequest` documentation now describes its parked-mutation
  behavior instead of claiming exact parity with the official client.
- Connection-state emissions now no-op after the client has closed its
  controller, preventing a concurrent fatal-error shutdown from being
  reclassified as an invalid server message.
- Query subscriptions now seed each newly attached listener from the latest
  cached, remote, or optimistic value instead of only seeding the first listener
  from the value captured at subscribe time.
- Reactive pagination now refuses `loadMore()` while any earlier page error is
  making the aggregate status `error`, avoiding invisible extra page
  subscriptions past the gap.
- `Connect` handshakes now omit `maxObservedTimestamp` when no timestamp has
  been observed yet, matching the optional wire shape used by the reference
  client.
- WebSocket `connectionCount` now advances only after a successful socket open,
  so failed pre-open connection attempts no longer inflate the next `Connect`
  frame.
- Reconnect-time auth refresh now cancels any scheduled token refresh timer,
  avoiding redundant concurrent forced token fetches around reconnects.
- Resume after auth gating now sends `Authenticate` before replaying query-set
  changes, matching reconnect ordering and avoiding auth-gated queries racing
  ahead of the refreshed identity.
- Reconnect sync tracking now waits for every active query to be re-confirmed
  by the server, even when a cached remote result existed before reconnect, so
  reconnect backoff is reset only after the session proves healthy.
- Deferred initial handshakes now no-op if a paused WebSocket closed before
  `resume()`, letting the scheduled reconnect rebuild the session instead of
  throwing from a send on a closed socket.
- Persistent auth rejections now reach the retry cap and report the client as
  signed out instead of resetting the confirmation-attempt counter after every
  forced token refresh.
- Optimistic updates that throw no longer leave behind poison layers that can
  wedge future server transitions into a reconnect loop.
- Terminal auth failures now clear the refresh callback, preventing later
  reconnects from refetching and reapplying a rejected token.
- Cached token refresh scheduling now clamps to the token's remaining lifetime so
  aged cached tokens are refreshed before their actual expiration.
- Reconnect-time auth refresh failures no longer abort the WebSocket handshake
  and trigger tight reconnect loops.
- The default Convex sync API version now uses a currently supported Convex
  client version, fixing browser WebSocket handshakes that cannot send the
  native `Convex-Client` header.
- A Transition that reflects an auth version the client has already moved past
  no longer confirms auth (it is recognized as stale), matching the existing
  guard against stale `AuthError`s. Prevents a superseded token from being
  reported as confirmed during rapid auth changes.
- Reconnect backoff now resets only after the client has re-synced every query,
  auth update, and request that predated the reconnect, instead of on every
  Transition or response. A server that repeatedly drops the connection before
  the client proves itself now keeps backing off instead of hammering it.
- An unrecoverable server `FatalError` now terminates the connection — pending
  requests fail, the connection state becomes `fatalError`, and no reconnect is
  attempted — instead of triggering a reconnect that could loop indefinitely.
- WebSocket messages are now processed strictly in order. A handler that awaits
  (an auth refresh or a reconnect) can no longer interleave with the next
  incoming message.
- Auth refresh scheduling reads the `exp`/`iat` claims defensively, so a
  malformed token can no longer raise a cast error that would otherwise escape
  into message handling and tear down the connection.
- Paginated results stay a gapless prefix while a page is still loading: a
  not-yet-loaded page no longer hides behind later, already-loaded pages.
- Special doubles (`NaN`, `±Infinity`, and `-0.0`) now always encode through the
  tagged `$float` wire form, including `-0.0` on the web, where it was previously
  encoded as a plain `0` and lost its sign.
- The after-unsubscribe query-result seed cache is now bounded (evicting the
  least-recently-written entry), so a long-lived client that subscribes to many
  distinct queries no longer grows it without bound.

## [0.1.5] - 2026-05-13

### Fixed

- Throws a clear error when a storage URL resolver returns `null` for a
  missing storage object.
- Aligns `TransitionChunk` handling with the current Convex protocol, including
  raw chunk payloads, zero-based part ordering, and invalid-chunk reconnects.
- Treats protocol `Ping` as a transport heartbeat without sending client
  protocol messages in response.
- Hardens auth refresh against stale token fetches, stale `AuthError` messages,
  and refresh scheduling that reused cached tokens.
- Schedules auth refresh from JWT expiration even when the token omits `iat`.
- Adds one-shot query timeout cleanup and safer disposal of temporary
  subscriptions.
- Rejects invalid Convex JSON field names and finite `$float` encodings.

### Added

- `ConvexClientConfig.queryTimeout`.
- `ConvexStorage.getFileUrl(..., useAction: true)` for action-based URL
  resolvers.

## [0.1.4] - 2026-04-30

### Added

- `ConvexClientConfig.connectImmediately` to defer opening the WebSocket until
  the first backend operation, auth update, or explicit reconnect.
- Structured query error payloads and server log lines on `QueryError` and
  one-shot `ConvexException` failures.
- Client protocol metadata fields for Convex component paths and auth
  impersonation metadata.
- Transport close diagnostics in WebSocket error logs.

### Fixed

- Replays safe queued requests after reconnect, including unsent actions and
  mutations awaiting their read-your-writes transition.
- Preserves pending request failures on dispose instead of leaving futures
  unresolved.
- Avoids logging structured Convex error payloads from failed requests.

## [0.1.3] - 2026-03-22

### Added

- `ConvexClient.reconnectNow(String reason)` — public method to force an immediate WebSocket reconnect, bypassing the backoff timer.

## [0.1.2] - 2026-03-21

### Improved

- Added comprehensive dartdoc comments on all public API
- Added example file for pub.dev scoring

## [0.1.1] - 2026-03-21

### Added

- Structured opt-in logging via `DartvexLogLevel`, `DartvexLogEvent`, and `DartvexLogger`
- `ConvexClientConfig` logging hooks for request, auth, storage, and transport diagnostics

## [0.1.0] - 2026-03-15

### Added

- Pure Dart Convex sync client
- WebSocket protocol implementation
- Read-your-writes mutations
- Multi-platform WebSocket (native + web)
- Auth framework with pluggable providers
- File storage helpers (ConvexStorage)
- One-shot query (queryOnce)
- Reconnection with exponential backoff
- Transition chunk reassembly
- Special value encoding
