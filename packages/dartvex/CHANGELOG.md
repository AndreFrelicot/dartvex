# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-06-12

### Added

- Query function log lines are now also written to the configured logger (tag
  `function`, `requestType: query`) as each transition is applied, mirroring the
  official client's per-transition `logForFunction`. They are emitted once per
  transition from the raw query modifications — never re-emitted on a reactive
  cache or optimistic-overlay update — and remain available on
  `QuerySuccess.logLines` as before.
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
- `paginatedQuery` is now part of the `ConvexFunctionCaller` interface (and
  delegated by `ConvexClientWithAuth`), so generated typed bindings can open
  paginated queries through any caller. **Breaking for implementors:** classes
  that `implement ConvexFunctionCaller` (or `ConvexAuthClient`) must add a
  `paginatedQuery` member.
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
- `ConvexClientConfig.queryTimeout`.
- `ConvexStorage.getFileUrl(..., useAction: true)` for action-based URL
  resolvers.
- `defaultWebSocketAdapterOverride`: a process-wide override consulted by
  `createDefaultWebSocketAdapter`, letting platform integrations (such as
  `dartvex_flutter` on iOS/macOS) swap the default WebSocket transport for
  every client without per-client configuration. An explicit
  `ConvexClientConfig.adapterFactory` still takes precedence.
  `createDefaultWebSocketAdapter` is now exported.
- `defaultHttpClientFactory` / `createDefaultHttpClient`: the same
  process-wide seam for the SDK's HTTP requests. `ConvexStorage` uploads now
  construct their default client through it; an explicitly provided
  `httpClient` still takes precedence.

### Changed

- Auth updates now gate the socket so requests can no longer be sent with
  absent or stale auth: the initial token fetch pauses the socket (buffering
  query-set changes and mutations, replayed together once the token is applied),
  and a reauth triggered by an `AuthError` stops the socket, fetches a fresh
  token, and restarts so it is replayed on a clean connection. Mirrors the
  official client's pause/resume and stop/restart auth gating.
- Auth setup now mirrors the official client's initial-refetch behavior: when
  the cached token fetch returns no token, the client immediately retries with a
  forced refresh before reporting unauthenticated state.
- A reconnect now replays the cached auth token from local state instead of
  re-fetching it from the auth provider, matching the official client. Token
  freshness on reconnect is driven by the scheduled refresh and by server
  `AuthError`s, so a transient auth-provider failure during a reconnect can no
  longer silently sign the user out.
- Auth token refresh is now scheduled from the token's own lifetime
  (`exp - iat`) minus `refreshTokenLeewaySeconds`, instead of from the device
  wall clock (`exp - now - 60`). Refresh timing is now immune to device clock
  skew; tokens without an `iat` claim do not schedule proactive refresh, and
  the delay is capped at 20 days.

- `reconnectBackoff` now defaults to empty, selecting the exponential backoff
  model. Provide an explicit non-negative schedule to keep fixed delays.
- `Connect.clientTs` and transition transit metrics now read from a monotonic
  clock (a one-time wall-clock anchor plus a monotonic `Stopwatch`) instead of
  `DateTime.now()`, so elapsed-time and server clock-skew estimates stay stable
  even when the device wall clock is corrected.
- `OptimisticLocalStore.setQuery(..., null)` now represents the real Convex
  `null` value. Use the new `clearQuery(...)` method to optimistically return a
  query to loading, matching the official client's `setQuery(..., undefined)`
  behavior with an explicit Dart API.

### Fixed

- The initial local emit of a fresh subscription now uses a deep snapshot of
  the args captured at `subscribe()` time. The first-listen microtask used to
  recompute the query token from the caller's live args map, so mutating that
  map between `subscribe()` and the first listen could resolve a *different*
  query's optimistic or cached value and emit it to the new subscriber. The
  wire path was already snapshot-protected inside the sync layer; the local
  read path now carries the same guarantee.
- `OptimisticLocalStore.getAllQueries` hands optimistic updates deep copies of
  each query's args instead of the live stored maps. For server-backed
  entries those maps are the very args re-encoded into every reconnect's
  query-set replay, so an update mutating them could silently poison the
  replayed query set. The official client is immune by construction (it
  re-parses args from the query token); dartvex now matches that guarantee.
- Errors emitted by a configured `ConnectivitySignal` stream are now caught and
  logged instead of surfacing as uncaught zone errors (isolate-fatal in a
  pure-Dart app). The restore subscription survives the error, so a later
  offline→online edge still reconnects immediately; losing a hint only means
  falling back to the normal reconnect backoff.
- Closing the late socket of a superseded native connect attempt now ignores
  close failures. That close typically runs on an already-dead network, and a
  failure on a socket nobody owns must not surface as an uncaught zone error.
- The native WebSocket adapter decodes binary frames with `allowMalformed`, so
  a peer sending invalid UTF-8 can no longer crash a pure-Dart isolate with an
  uncaught `FormatException` thrown from the socket listener. The garbled
  message fails JSON parsing upstream instead, driving the normal
  `InvalidServerMessage` reconnect.
- A close event from a superseded WebSocket is now ignored once a newer
  connection is open. Previously, when a socket's close on a dead network
  outlived the platform close timeout and its close event was only delivered
  after a fast reconnect (for example on a connectivity restore or app
  resume), the stale event was treated as the current connection closing —
  tearing down the healthy successor with a spurious disconnect and a
  scheduled reconnect. The official client cannot reach this state because it
  detaches the close handler from sockets it closes deliberately.
- A superseded socket's close event is also ignored while the successor's
  connect attempt is still in flight. Previously a stale close landing in
  that window consumed the new attempt's close handling, so once the connect
  succeeded, the connection's next real close was silently dropped — no
  reconnect was ever scheduled again and even `reconnectNow` became a no-op
  until the client was disposed or reauthed. An adapter whose in-flight
  socket dies must fail the pending `connect()` future (both built-in
  adapters do); the `WebSocketAdapter.closeEvents` contract now documents
  this.
- An `AuthHandle` from `setAuthWithRefresh` now stays cancellable after
  `updateAuthToken` pushes a new token into the same flow. Handles bind to the
  refresh-flow identity instead of the auth generation, so a token update —
  which supersedes in-flight fetches but keeps the flow alive — no longer
  silently orphans the caller's handle (previously a later `handle.cancel()`,
  for example from `ConvexClientWithAuth.dispose()`, became a no-op and left
  the scheduled token refresh running). A handle from a genuinely replaced
  flow still cannot tear down its successor.
- Mutation, action, and subscription arguments are now validated and
  deep-snapshotted eagerly, when the call is made, matching the official
  client's eager `convexToJson(args)`. An unsupported argument value (for
  example a `DateTime`, a `Set`, or a `$`-prefixed field name) now fails the
  call immediately with an `ArgumentError` instead of throwing later inside
  the transport send path — where it closed a healthy connection and was
  replayed by every reconnect, flapping the socket forever while the caller's
  future never resolved. The snapshot also means mutating a nested argument
  collection after the call can no longer change what is sent (or re-sent on
  reconnect).
- A socket pause that lands while an asynchronous resume is still building its
  replay messages no longer drops them on a live connection: the resume now
  hands the drained messages to the transport without yielding when they are
  available synchronously (the production path), and an async resume that is
  re-paused mid-build forces a clean `PausedDuringResume` reconnect whose
  deferred handshake rebuilds the query set, auth, and unsent requests instead
  of silently losing them.
- A `mutate()` or `action()` raced by a `close()` in the same event no longer
  reports a spurious unhandled `ConvexException` while the request future is
  failed in the microtask gap before the method's own await attaches; the
  error itself still reaches the caller unchanged.
- A `setAuthWithRefresh` superseded while its initial token fetch was still
  pending no longer leaves the transport paused forever. `setAuth`,
  `clearAuth`, `updateAuthToken`, and a cancelled auth handle now release the
  socket pause inherited from the flow they replaced (resuming an unpaused
  socket is a no-op, and a flow superseded by a newer `setAuthWithRefresh`
  still hands the gating to that flow, which resumes on its own). Previously a
  logout — or any new fixed token — issued while the initial fetch was hung
  left every query and mutation buffering indefinitely, and the stall survived
  reconnects.
- Cancelling the `AuthHandle` of a superseded `setAuthWithRefresh` flow is now
  a no-op instead of tearing down the current flow's refresh state (which
  could stop token refreshes for the active session).
- A connect attempt superseded by a reauth `stop()`/`restart()` cycle while
  its socket was still opening now abandons its handshake instead of — in the
  worst interleaving — writing a second `Connect` frame onto the restarted
  attempt's socket and double-counting the connection. `stop()` now also
  closes a half-open socket, mirroring the official client's `stop()` on a
  "connecting" socket.
- Reconnect now re-declares the query set even when it is empty:
  `prepareReconnect` always emits a `ModifyQuerySet(baseVersion: 0,
  newVersion: 1)`, matching the official client's `restart()`, which sends one
  unconditionally on every reconnect. The previous behavior (sending nothing for
  an empty query set) was equivalent but is now byte-for-byte aligned with the
  official wire sequence.
- Query journals now honor the protocol's explicit `null` journal as an empty
  journal, clearing any previously stored cursor before the next reconnect
  replay.
- A transition modification that omits the `journal` field entirely now leaves
  the stored journal untouched, matching the official client's
  `journal !== undefined` guard; only a present `null` clears the stored
  cursor.
- A mutation or action queued while the socket is paused for auth is no longer
  silently dropped when a concurrently arriving server message drains the
  outgoing queue: drained messages are re-queued through the normal flush path,
  so the request goes out on resume instead of hanging until the next
  reconnect.
- The connect handshake no longer yields to the event loop between the
  `Connect` frame and the session-restoring messages, and an asynchronous
  connected-callback that gets paused mid-handshake forces a clean reconnect,
  so a pause landing during the handshake can no longer leave the connection
  without its re-declared query set and replayed requests.
- Mutation and action function log lines are now routed to the configured
  logger for both successful and failed responses, matching the official
  client's response log handling while keeping structured failure logs sanitized.
- A read-your-writes mutation replayed on reconnect no longer re-logs its
  function output. When the server re-sends the response for a mutation that has
  already completed and is only awaiting its transition, those duplicate log
  lines are now suppressed, matching the official client which skips
  already-completed requests before logging.
- The native WebSocket adapter now drops messages from a socket that a later
  `connect()` or `close()` has already superseded, matching the web adapter. A
  closing socket's trailing frames can no longer reach the sync layer, where a
  stale transition would mismatch the reset version and force a spurious
  reconnect.
- Auth reauth now matches the official client's retry budget: only a rejected
  *fresh* token counts toward the give-up limit, so a single cached-token
  rejection no longer shortens the number of fresh-token retries before the
  client falls back to unauthenticated.
- A transient auth-provider failure during a scheduled token refresh no longer
  logs the user out. The internal auth token bridge now lets provider errors
  propagate (the auth manager already handles them per context) instead of
  collapsing every failure to a null token that read as a definitive logout, so
  a network blip while a token is still valid no longer ends the session — a
  genuine logout still flows through a server `AuthError`. Matches the official
  client, where a throwing token fetcher does not by itself log the user out.
- The default WebSocket inactivity timeout now matches the official Convex
  client's 60-second threshold, reducing false reconnects while large messages
  are in flight.
- An inactivity-timeout close that throws now falls back to a synthetic
  disconnect, so the client still reconnects instead of sitting idle on a dead
  socket when no close event arrives.
- WebSocket close failures during reconnect, invalid-message recovery, shutdown,
  and auth revalidation are now best-effort, so a platform close error can no
  longer strand the client before reconnect or auth restart bookkeeping runs.
- `ConvexStorage.getFileUrl` now throws a `ConvexStorageException` instead of a
  `StateError` when the resolver returns no URL (e.g. a missing or deleted
  file), so a normal runtime condition is no longer reported as API misuse.
- `ConvexStorage.uploadFile` now validates malformed upload URL resolvers and
  successful upload responses with typed Dartvex exceptions instead of leaking
  runtime casts or JSON parse failures.
- Reactive pagination now rejects malformed `PaginationResult` objects whose
  `continueCursor` is missing or non-string, preventing duplicate page loads or
  load loops.
- Successful mutations and actions now surface server-side function log lines
  through the configured logger at info level, matching the official client's
  function-output visibility.
- WebSocket reconnect paths that discover an already-closed adapter now run the
  same disconnect bookkeeping as normal close events, so state listeners and
  disconnect callbacks are not skipped before reconnecting.
- Reactive pagination now tears down both split-half subscriptions when either
  half of a split page fails and falls back to the original un-split page
  (which covers the same range), retrying the split once the page produces a
  fresh result. A transient split failure no longer leaks subscriptions or pins
  the whole query to an error.
- Auth confirmations are now ignored unless a token update is actually pending,
  and reauth confirmations no longer re-emit an already-authenticated public
  state.
- Auth refresh flows now reset to unauthenticated state when a scheduled refresh
  returns no token, preventing stale refresh callbacks from resurrecting a
  failed auth flow.
- Query subscriptions now emit `QueryLoading` when an optimistic update clears a
  live query, and one-shot queries ignore that loading state until a concrete
  success or error arrives.
- Reactive paginated queries now consume `QueryLoading` page events, so a loaded
  page cleared by an optimistic update returns to loading instead of showing
  stale rows.
- Reactive paginated queries now seed their first page synchronously from the
  current local/cache result when available, avoiding a loading flash on warm
  remounts.
- Reactive paginated queries now seed split-half pages synchronously from warm
  local/cache results when available, avoiding a loading flash after an
  oversized page is re-split.
- Reactive paginated queries now cancel in-flight split-half subscriptions when
  the original page returns to loading or changes before the split completes,
  preventing stale split results from replacing fresh data.
- Mutations whose optimistic update throws now cancel their tracked request
  immediately, preventing the failed mutation from being sent by a later flush.
- `ConvexClientWithAuth.logout()` now clears local auth state even if the
  provider logout call fails, preventing a stale authenticated wrapper after a
  best-effort sign-out.
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
- `jsonToConvex` now preserves incoming object field order on decode, matching
  the reference client; encoding remains canonical and sorted.
- WebSocket `connectionCount` now advances only after a successful socket open,
  so failed pre-open connection attempts no longer inflate the next `Connect`
  frame.
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
- Terminal auth failures now clear the refresh callback, so a rejected token is
  not refetched and reapplied by a later `AuthError`.
- Cached token refresh scheduling now clamps to the token's remaining lifetime so
  aged cached tokens are refreshed before their actual expiration.
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
- Throws a clear error when a storage URL resolver returns `null` for a
  missing storage object.
- Aligns `TransitionChunk` handling with the current Convex protocol, including
  raw chunk payloads, zero-based part ordering, and invalid-chunk reconnects.
- Treats protocol `Ping` as a transport heartbeat without sending client
  protocol messages in response.
- Hardens auth refresh against stale token fetches, stale `AuthError` messages,
  and refresh scheduling that reused cached tokens.
- Skips proactive auth refresh when a JWT omits `iat`, matching Convex's need
  for a known token lifetime before scheduling refresh.
- Adds one-shot query timeout cleanup and safer disposal of temporary
  subscriptions.
- Rejects invalid Convex JSON field names and finite `$float` encodings.

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
