# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-06-12

### Added

- `ConvexClientRuntime` now preserves successful query log lines and maps real
  core optimistic query emissions to `source: cache` with
  `hasPendingWrites: true`.
- Rich connection status: `ConvexRuntimeClient` gains `connectionStatus` (a
  `Stream<ConnectionStatus>`) and `currentConnectionStatus`, and the new
  `ConvexConnectionStatusBuilder` rebuilds on the detailed status (inflight
  counts, retry count, loading, `hasEverConnected`). `ConnectionStatus` is
  re-exported from `dartvex`. The coarse `ConvexConnectionBuilder` and
  `ConvexConnectionIndicator` are unchanged.
- `PaginatedQueryBuilder` is now backed by the core reactive pagination engine:
  loaded pages update live as their data changes and stay gapless at page
  boundaries, instead of being one-shot reads. The widget API
  (`query`/`builder`/`fromJson`/`args`/`pageSize`/`client`) and `PaginationStatus`
  are unchanged. `ConvexRuntimeClient` gains `paginatedQuery(...)` returning a
  `ConvexRuntimePaginatedQuery`, and `ConvexPaginatedResult` /
  `ConvexPaginationStatus` are re-exported from `dartvex`.
- `ConvexMutation.optimisticUpdate` applies an optimistic update while the
  mutation is in flight, overlaying query results instantly and rolling back
  when it completes or fails. `ConvexRuntimeClient.mutate` now accepts an
  optional `OptimisticUpdate`, and `OptimisticLocalStore` / `OptimisticUpdate` /
  `OptimisticQueryEntry` are re-exported from `dartvex` for convenience.
- `ConnectivityPlusSignal`, a `connectivity_plus`-backed `ConnectivitySignal`.
  Pass it to `ConvexClientConfig.connectivitySignal` so the client reconnects
  immediately when the device regains network connectivity.
- `ConvexAuthRefreshingBuilder`, a widget that rebuilds with the client's
  auth-refreshing state (`true` while auth is being recovered after a server
  rejection). `ConvexRuntimeClient` now exposes `authRefreshing` and
  `currentAuthRefreshing`, backed by `ConvexClient.authRefreshing`.
- `ConvexRuntimeQueryLoading`, emitted when the core client reports an
  optimistic query clear/loading state.
- NSURLSession-backed network transports on iOS and macOS, installed
  automatically at startup via Dart plugin registration
  (`DartvexFlutterPlugin.registerWith()`). All SDK network paths — the sync
  WebSocket, storage uploads, auth endpoints, asset-cache downloads, and
  `ConvexFileDownloader` — now use the same system network path as Safari and
  native apps instead of raw `dart:io` sockets. POSIX sockets are discouraged
  by Apple (they bypass VPNs, proxies, and per-app network policy; see
  dart-lang/sdk#41376) and are blackholed with `errno 65` on some iOS devices.
  Apps can opt out by resetting `defaultWebSocketAdapterOverride` and
  `defaultHttpClientFactory` to `null` early in `main()`, or override per
  client with `ConvexClientConfig.adapterFactory` / explicit `httpClient`
  parameters as before. `installCupertinoTransport()` is exported to
  re-install the defaults after an opt-out. Adds `cupertino_http`, `http`,
  `objective_c`, and `web_socket` dependencies; the package is now a
  Dart-only plugin on iOS/macOS.
- The WebSocket transport uses a session-owning NSURLSession socket: the
  `URLSession` created for each connection attempt is invalidated once the
  connection ends. Upstream `CupertinoWebSocket` never invalidates its
  session, which leaks a native session per connect — a real cost for a sync
  client that reconnects indefinitely (dart-lang/http#1282).
- `defaultWebSocketAdapterOverride` and `defaultHttpClientFactory` are
  re-exported from `dartvex_flutter`, so the documented transport opt-out is
  reachable without a direct `dartvex` import.

### Changed

- Requires `dartvex` `^0.2.0` so web consumers resolve the current
  JavaScript-compatible value codec.
- Clarifies in the README and API docs that disk-backed file/image cache
  helpers (`ConvexAssetCache`, `ConvexCachedImage`, `ConvexOfflineImage`, and
  progress-download image helpers) are native-only; web apps should render
  signed storage URLs directly.
- `ConvexQuery` now renders loading when it receives an optimistic clear event,
  and `hasData` represents a concrete query result even when that result is
  Convex `null`.
- `PaginatedQueryBuilder` now uses the core paginated query's synchronous
  current snapshot on the first build, so warm remounts can render cached pages
  without a loading frame.

### Fixed

- The NSURLSession WebSocket decodes peer close reasons with `allowMalformed`.
  A close frame carrying invalid UTF-8 previously threw out of the session
  delegate callback, which skipped the close event entirely — leaving the sync
  layer blind to the disconnect until its inactivity timeout — and leaked the
  owned native session. The close reason is diagnostic-only, so replacement
  characters are harmless.
- `ConvexProvider` no longer lets the disposed-client error escape into the
  Flutter lifecycle dispatch when the app resumes after an externally owned
  client (`disposeClient: false`) was disposed in the background. The
  best-effort `AppResumed` reconnect is skipped instead.
- Inline closures no longer reset widget state on parent rebuilds: `decode`
  (`ConvexQuery`, `ConvexMutation`, `ConvexAction`), `fromJson`
  (`PaginatedQueryBuilder`), and `optimisticUpdate` (`ConvexMutation`) are
  treated as render/call-time mappings instead of subscription identity.
  Previously a parent rebuild that passed a new closure instance resubscribed
  the query, reset a paginated list back to its first page, or wiped the
  request snapshot. Changing `decode`/`fromJson` now re-decodes the current
  value (or re-maps the loaded items) in place.
- `ConvexMutation`/`ConvexAction` no longer surface unhandled zone errors when
  the returned future is ignored (the normal builder pattern), both for the
  in-flight guard and for request failures already reported through the
  snapshot. Awaiting callers still receive the same errors.
- `FakeConvexClient.dispose()` no longer throws a
  `ConcurrentModificationError` when a subscription listener reacts to its
  done event by canceling a subscription (done events are delivered
  synchronously while dispose closes the fake's controllers).
- The NSURLSession WebSocket adapter decodes binary frames with
  `allowMalformed`, so a peer sending invalid UTF-8 can no longer throw an
  uncaught `FormatException` out of the socket listener. The garbled message
  fails JSON parsing upstream instead, driving the normal
  `InvalidServerMessage` reconnect.
- `ConvexImage` and `ConvexCachedImage` now treat a changed runtime client as a
  new load identity, preventing stale images from a previous provider/client
  and avoiding implicit retries when unchanged failed loads rebuild.
- Reactive query and paginated-query widgets now ignore late events from
  canceled subscriptions after inputs change, preventing stale results from
  overwriting the newest subscription state.
- Raw errors emitted by custom runtime query or paginated-query streams are now
  mapped into widget error state instead of escaping as unhandled Flutter stream
  errors.
- Action and mutation builders now ignore stale in-flight completions after
  their action/mutation or client changes, so old results cannot overwrite the
  new request state.
- `FakeConvexClient` now broadcasts duplicate query subscriptions and paginated
  queries with the same name to every live handle instead of only the latest.
- `FakeConvexClient` now deep-snapshots query, subscription, mutation, and
  action arguments before invoking handlers, matching the real client behavior
  and preventing caller-side map mutations from changing deferred fake results.
- Closes file-download HTTP clients and rejects non-success responses instead
  of returning error bodies as image bytes.
- `ConvexFileDownloader.download` now applies a configurable `idleTimeout`
  (default 30s) to connecting, awaiting response headers, and the gap between
  body chunks, so a stalled server fails with a `TimeoutException` instead of
  leaving `ConvexImage` loading forever with an open HTTP client. It is an idle
  (inter-event) bound, so large downloads that keep progressing are never cut
  off.
- Ignores stale async image/cache loads after widget inputs change.
- Resets paginated queries when query inputs or client instances change.
- Returns failed futures for overlapping action/mutation requests instead of
  throwing synchronously.
- Preserves structured query error data and server log lines in runtime errors.
- Supports action-based storage URL resolvers in `ConvexImage` and
  `ConvexCachedImage`.
- Normalizes malformed storage URL resolver results in `ConvexImage` and
  `ConvexCachedImage` to `ConvexStorageException`, instead of surfacing raw
  cast errors for non-string values.
- Excludes build artifacts from the package archive.
- `ConvexAssetCache.dispose()` now closes the HTTP client the cache created
  for its file service (`CacheManager.dispose()` never does), releasing its
  platform resources — an NSURLSession on iOS/macOS.
- `ConvexFileDownloader.download` now bounds draining a non-2xx error
  response body by `idleTimeout`, so a stalled error response fails with the
  status error instead of hanging the download forever.

## [0.1.4] - 2026-04-30

### Fixed

- Updated the package example runtime to implement `reconnectNow`, matching the
  public `ConvexRuntimeClient` contract.

### Improved

- Refreshed README metadata, logo links, and installation snippets for pub.dev.

## [0.1.3] - 2026-03-22

### Added

- `ConvexRuntimeClient.reconnectNow(String reason)` — propagate reconnect to the Flutter runtime layer.
- App lifecycle listener in `ConvexProvider` — automatically forces a reconnect when the app resumes from background if the connection is not active.

## [0.1.2] - 2026-03-21

### Improved

- Added comprehensive dartdoc comments on all public API
- Added example file for pub.dev scoring

## [0.1.1] - 2026-03-21

### Added

- `ConvexCachedImage` for disk-cached Convex storage images backed by `ConvexAssetCache`

### Fixed

- Asset cache test setup for publish validation
- Cached image analyzer warning cleanup

## [0.1.0] - 2026-03-15

### Added

- ConvexQuery reactive widget for query subscriptions
- ConvexMutation widget for executing mutations
- ConvexAction widget for action invocation
- ConvexProvider for dependency injection
- ConvexConnectionBuilder and ConvexConnectionIndicator
- ConvexAuthProvider and ConvexAuthBuilder
- ConvexImage widget for displaying storage images
- PaginatedQueryBuilder for cursor-based pagination
- FakeConvexClient test helper for testing
- ConvexOfflineImage with asset caching
- ConvexAssetCache for offline binary asset caching
- Runtime-interface based integration via ConvexClientRuntime
- Widget tests, example app, and package documentation
