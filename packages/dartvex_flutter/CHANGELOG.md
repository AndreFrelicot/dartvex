# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-11-05

### Added

- `PaginatedQueryBuilder.errorBuilder` (`PaginatedQueryErrorWidgetBuilder`)
  receives the error object of a failed query — the page's server error or a
  decode failure — plus the items loaded so far and a `retry` callback that
  restarts the query. The existing `builder` signature is unchanged.
- `ConvexDecodeException` (error, stack trace and raw value), used by
  `ConvexQuery`, `ConvexMutation`, `ConvexAction` and `PaginatedQueryBuilder`
  when decoding a successful result fails.
- `ConvexProvider.of(context).functionCaller` (extension
  `ConvexRuntimeFunctionCaller`) returns a core `ConvexFunctionCaller` for the
  provider's client, so generated `ConvexApi` bindings and `ConvexStorage`
  can be built below a provider. `ConvexClientRuntime` returns its wrapped
  client (now also exposed as `ConvexClientRuntime.client`); custom runtime
  clients can opt in through `ConvexFunctionCallerSource`.
- `FakeConvexClient`: optional `args:` filter on `emitSubscription`,
  `emitSubscriptionError` and `emitPaginated` (emissions stay name-scoped by
  default); `source` / `hasPendingWrites` on `emitSubscription`;
  `emitSubscriptionLoading`; `error` on `emitPaginated`; recorded
  `queryCalls` / `mutationCalls` / `actionCalls` (`FakeConvexCall`, including
  the mutation's `optimisticUpdate`); `isDisposed`;
  `FakeConvexPaginatedQuery.args` and `lastLoadMoreNumItems`;
  `FakeConvexSubscription.args`; and `functionCaller` support. The dartdoc
  lists where the fake intentionally differs from the real client.
- `ConvexImage.errorBuilder` and `ConvexCachedImage.errorBuilder`
  (`ConvexImageErrorBuilder`) receive the error and a `retry` callback.
  **Breaking (behavior):** without `errorBuilder` or `errorWidget`, load
  failures are now reported to `FlutterError.reportError` (like
  `Image.network`) instead of being invisible.
- `ConvexImage.httpClient` and `ConvexFileDownloader.download(client:,
  abortTrigger:)`: downloads can use a caller-owned client, and an in-flight
  download can be aborted.

### Changed

- **Breaking:** the unnamed `ConvexAssetCache` constructor is now a
  factory: instances with the same `cacheKey` share one ref-counted
  `CacheManager` (classes extending `ConvexAssetCache` must use
  `ConvexAssetCache.custom`). `ConvexOfflineImage` now reports "no cached
  asset and no URL" as a `ConvexStorageException` instead of a `String`.
- The native-only media helpers (`ConvexImage`, `ConvexCachedImage`,
  `ConvexOfflineImage`, `ConvexAssetCache`, `ConvexFileDownloader`) are now
  exported through a conditional export: web (JS and WASM) builds get
  API-compatible stand-ins that render the error state or fail with an
  `UnsupportedError`, so the package's web import graph no longer reaches
  `dart:io` or `flutter_cache_manager` (WASM-compatible on pub.dev). Native
  behavior is unchanged. On web, `ConvexAssetCache.custom` takes an `Object`
  and `ConvexAssetSnapshot.file` is always `null`.

- **Breaking (tests):** `FakeConvexClient` now behaves like a disposed
  `ConvexClient` after `dispose()`: `subscribe`, `paginatedQuery` and `reconnectNow` throw and
  `query` / `mutate` / `action` reject with
  `ConvexException('ConvexClient has been disposed')`; emissions are
  ignored. `FakeConvexPaginatedQuery.loadMore` returns `true` only while the
  current status is `canLoadMore`, like the real engine (it always returned
  `true`).

- **Breaking:** Requires Dart `^3.10.0` and Flutter `>=3.38.1`, and on Apple
  platforms iOS 15 / macOS 12 or later; apps must raise
  `IPHONEOS_DEPLOYMENT_TARGET` / `MACOSX_DEPLOYMENT_TARGET` (and their Podfile
  `platform`, if any). `cupertino_http` is now `>=3.1.0 <4.0.0` (up from
  `^2.4.0`, which excluded the current major and conflicted with apps already
  on it), `objective_c` `>=9.5.0 <10.0.0` and `http` `^1.5.0`. On Flutter
  3.47 and later pub resolves `cupertino_http` 3.1.1 / `objective_c` 9.6,
  which carry upstream native memory-leak fixes; earlier Flutter releases pin
  `meta` below what those versions need and get 3.1.0 / 9.5. (Flutter 3.38.0
  itself shipped a prerelease Dart 3.10 build that `^3.10.0` does not accept.)
- `connectivity_plus` now accepts `>=6.1.0 <8.0.0`, so apps on
  `connectivity_plus` 7.x can depend on `dartvex_flutter`. (7.x itself raises
  the Android build requirements to AGP 8.12.1, Gradle 8.13 and Kotlin 2.2.)
- The NSURLSession WebSocket transport now runs every connection on one
  shared, process-wide `URLSession` and sends the `Convex-Client` header on
  the handshake request. Foundation never fully releases a session that has
  run a WebSocket task, even after invalidation, so the previous
  session-per-connection design still leaked a native session on every
  reconnect.
- **Breaking:** decode failures are now a public `ConvexDecodeException`
  everywhere:
  `ConvexQuery` used a private wrapper type, and `ConvexMutation` /
  `ConvexAction` surfaced the raw decoder error, indistinguishable from a
  rejected request even though the server had already committed the write.
  Code catching the raw decoder error (for example `on TypeError`) from a
  mutation or action future must catch `ConvexDecodeException` instead.
- **Breaking (behavior):** `PaginatedQueryBuilder` reports item decode
  failures to `FlutterError.reportError` (still contained: no `ErrorWidget`),
  instead of silently switching to the error status. Widget tests that pump
  undecodable items now see the reported error.
- `ConvexClientRuntime` no longer keeps a `connectionState` listener (it reads
  the wrapped client's state directly), and two wrappers around the same
  client with the same `disposeClient` are now equal. A wrapper re-created
  inline in a `build` method no longer makes every descendant resubscribe,
  reset pagination, or re-download images, and no longer leaks a listener per
  rebuild.
- `ConvexProvider` no longer calls `reconnectNow` on app resume for a lazy
  client (`connectImmediately: false`) that has not started yet, which opened
  a socket before the first backend operation or auth update.
- `ConvexMutation` and `ConvexAction` share one request state machine; their
  single-flight behavior (a call made while another is in flight rejects with
  a `StateError`) is unchanged and now documented.
- `dev_dependencies`: `flutter_lints` `^6.0.0`.
- README: no longer promises that additions to `ConvexRuntimeClient` are
  non-breaking for custom implementations, and documents the sample
  `ConvexLocalClient` adapter in the example app.
- The `ConvexQuerySource` dartdoc now states that, with `ConvexClientRuntime`,
  `source` only reflects pending optimistic writes: a subscription seeded from
  the core's recently-unsubscribed cache is reported as `remote` and may be
  stale until the next server result.

### Fixed

- On iOS and macOS the default HTTP client (used by storage uploads, asset
  downloads and auth adapters such as `dartvex_auth_better`) kept cookies in
  the shared, persistent `HTTPCookieStorage` and attached them to later
  requests. A Better Auth session cookie stored by sign-in then made sign-out
  and the next sign-in fail with 403 (missing Origin) and could override the
  explicit bearer token. Both NSURLSession transports (the default HTTP
  client installed by `installCupertinoTransport()` and the WebSocket) now
  use an ephemeral, cookie-less configuration, matching the `dart:io` and web
  transports, which never sent cookies.
- HTTP clients created by the default factory on Apple platforms can be
  closed while a request is still running (for example from a `finally`
  after a timeout); `cupertino_http` 3 would otherwise throw a `StateError`
  that masks the original failure. The native session is released once the
  last request finishes.
- The NSURLSession WebSocket close/error state machine is now covered by unit
  tests through a native-task seam.
- `ConvexAuthBuilder`, `ConvexConnectionBuilder`,
  `ConvexConnectionStatusBuilder` and `ConvexAuthRefreshingBuilder` kept the
  previous client's last value after the client was swapped (for example a
  fresh signed-out auth client kept showing the signed-in user). They now
  re-seed from the new client's current value.
- `ConvexQuery` kept the previous client's data (with `hasData: true`) after a
  client swap, even next to the new client's error. A client change now resets
  to the loading state; changing only the query or args on the same client
  still keeps the previous data while refreshing.
- Widgets driven by the core's synchronous streams no longer throw
  "setState() called during build" when the client emits during a build or
  layout pass — for example `loadMore()` called from a `ListView.itemBuilder`,
  a lazy client connecting because a descendant subscribed, or
  `loginFromCache()` from a descendant's `initState`. The rebuild is deferred
  to after the frame.
- Calling the `ConvexMutation` / `ConvexAction` executor after the widget was
  unmounted threw before the request was sent; the request is now sent and
  only the snapshot update is skipped.
- `ConvexQuery` renders the client's live result in its first frame, instead
  of a loading frame, when another widget already holds a live subscription to
  the same query and arguments through a `ConvexClientRuntime` of the same
  client.
- `ConvexQuery` and `PaginatedQueryBuilder` no longer throw out of lifecycle
  methods (replacing the subtree with an `ErrorWidget`) when the client
  rejects the subscription synchronously, for example a disposed client. They
  show an error state and retry on the next dependency or client change.
- `PaginatedQueryBuilder` only decodes items whose raw value changed since the
  previous emission, and no longer copies the item list on every build.
- A `FakeConvexClient` query handler that throws now delivers a
  `ConvexRuntimeQueryError` event (an error snapshot) instead of an uncaught
  microtask error. The `mutate` dartdoc no longer suggests observing the
  optimistic update from a handler, which never received it.
- `ConvexAssetCache(cacheKey: k)` instances (including
  `ConvexAssetCache.shared`) each opened their own `CacheManager` over the
  same database and file directory, and disposing one closed the store under
  the others. They now share one store per key, closed (with its HTTP client)
  when the last instance is disposed; `dispose()` is idempotent.
- `ConvexAssetCache.prefetch(force: true)` (also used by `ConvexCachedImage`
  after a client or resolver change) removed the cached file before
  downloading, so a failed refresh lost the offline copy. The new file now
  replaces the old one only after a successful download.
- `ConvexOfflineImage` no longer flashes a loading frame (and re-reads the
  cache) when only its `url` changes — rotating signed URLs, or `url`
  becoming `null` offline — while the asset is already shown.
- `ConvexImage` aborts the running download when it is disposed or starts a
  new load, and reuses one HTTP client (one connection pool, one URLSession
  on Apple platforms) for every image instead of creating one per download.
- `ConvexCachedImage` compares clients with `==`, so an equal re-created
  `ConvexClientRuntime` no longer bypasses the cache and re-downloads.
- The `ConvexImage` dartdoc `onProgress` example printed `p * 100`; it now
  uses `p.progress`.

## [0.2.0] - 2026-06-12

### Changed

- **Breaking for implementors** (noted after release): classes that
  `implement ConvexRuntimeClient` must add the members introduced in this
  release — `paginatedQuery`, `connectionStatus`, `currentConnectionStatus`,
  `authRefreshing`, `currentAuthRefreshing` — and the optional
  `OptimisticUpdate? optimisticUpdate` parameter on `mutate`. Code that only
  uses `ConvexClientRuntime` or `FakeConvexClient` is unaffected.

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
- Requires Dart `^3.8.0` and Flutter `>=3.32.0`, matching the minimums
  required by the Cupertino transport dependencies.
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

- `ConvexQuery` and `PaginatedQueryBuilder` now compare rebuild arguments
  against the deep-snapshotted args used for the active subscription. Reusing a
  `Map` and mutating it in place between parent rebuilds now correctly
  resubscribes to the new query instead of leaving the widget attached to the
  previous args.
- The NSURLSession WebSocket decodes peer close reasons with `allowMalformed`.
  A close frame carrying invalid UTF-8 previously threw out of the session
  delegate callback, which skipped the close event entirely — leaving the sync
  layer blind to the disconnect until its inactivity timeout — and leaked the
  owned native session. The close reason is diagnostic-only, so replacement
  characters are harmless.
- The NSURLSession WebSocket now turns unexpected receive/send errors into an
  abnormal close instead of throwing out of the async task callback, ensuring
  the owned session is invalidated and the sync layer sees a disconnect.
- The NSURLSession WebSocket adapter now converts raw `socket.events` stream
  errors into abnormal close events and cleans up the socket best-effort,
  instead of letting those errors escape the zone before the core reconnect
  manager can handle them.
- `ConvexProvider` no longer lets the disposed-client error escape into the
  Flutter lifecycle dispatch when the app resumes after an externally owned
  client (`disposeClient: false`) was disposed in the background, including
  when that error is reported by the reconnect future after lifecycle dispatch
  returns. The best-effort `AppResumed` reconnect is skipped instead.
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
