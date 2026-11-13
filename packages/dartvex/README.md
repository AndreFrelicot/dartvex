<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
  </a>
</p>

# dartvex

Pure Dart client for [Convex](https://convex.dev) with WebSocket sync, type-safe values, and reactive subscriptions. Works on iOS, Android, web, and desktop.

<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-poster.webp" width="900" alt="Dartvex Flutter demo — real-time chats running on iOS and macOS" />
  </a>
</p>

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| **[`dartvex`](https://pub.dev/packages/dartvex)** | Core client — WebSocket sync, subscriptions, auth |
| [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) | Flutter widgets — Provider, Query, Mutation |
| [`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen) | CLI code generator — type-safe Dart bindings from function validators |
| [`dartvex_local`](https://pub.dev/packages/dartvex_local) | Offline support — SQLite cache, mutation queue |
| [`dartvex_auth_better`](https://pub.dev/packages/dartvex_auth_better) | Better Auth adapter |

> **Building a Flutter app?** Start with [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) — it pulls in `dartvex` automatically.

Source and full docs: [github.com/AndreFrelicot/dartvex](https://github.com/AndreFrelicot/dartvex)

## Features

- Pure Dart — no Rust FFI, no Flutter dependency, works in CLI/server apps
- Full Convex sync protocol: subscribe, query, mutate, action
- Read-your-writes mutation semantics
- Transition chunk reassembly
- Special value encoding (`$integer`, `$bytes`, `$float`)
- Structured query errors with Convex error data and server log lines
- Auth framework with pluggable `AuthProvider<T>` abstraction
- One-shot query via `queryOnce<T>()` for non-reactive reads
- File storage helpers via `ConvexStorage` (upload/download)
- Reconnection with bounded handshake, jittered exponential backoff,
  connectivity-triggered immediate reconnect, full query set rebuild, and safe
  replay of queued mutations
- Optimistic updates with automatic rollback when the mutation settles or fails
- Reactive, gapless pagination via `paginatedQuery`
- Rich connection status (inflight counts, retries, `hasEverConnected`) plus an
  auth-refreshing signal for "authenticating…" indicators
- Native and browser WebSocket adapters (conditional import)
- Structured opt-in logging for transport, auth, and storage diagnostics
- Tracks the official Convex JavaScript client **1.49.0** (see
  [Compatibility](#compatibility))

## Platform Support

| Platform | Default transport | Status |
|----------|-------------------|--------|
| iOS / Android | `dart:io` WebSocket | Tested |
| macOS / Linux / Windows | `dart:io` WebSocket | Tested |
| Web (JS / Wasm) | `package:web` WebSocket | Tested |

The web adapter is selected automatically via conditional import. These are
the defaults for the pure-Dart package; in Flutter apps,
[`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) automatically
replaces the `dart:io` transport on iOS and macOS with an NSURLSession-backed
one (the same system network path Safari and native apps use), via the
process-wide `defaultWebSocketAdapterOverride` / `defaultHttpClientFactory`
seams exported by this package. An explicit `ConvexClientConfig.adapterFactory`
always takes precedence.

## Installation

```yaml
dependencies:
  dartvex: ^0.3.0
```

Requires Dart `^3.6.0`.

## Compatibility

Dartvex 0.3.0 implements the sync protocol, auth flow, and value encoding of
the official Convex JavaScript client **1.49.0** (`convex` on npm). Behavior
described in these docs and the CHANGELOG as matching "the official client"
refers to that release. The version is exported as `convexSyncApiVersion`
and sent as the default `ConvexClientConfig.apiVersion` (the
`/api/<version>/sync` path segment); it is bumped deliberately, after
reviewing the official client's changes, in a Dartvex release. The default
`clientId` is `dartvex-<version>` (`dartvexVersion`).

## Usage

```dart
import 'package:dartvex/dartvex.dart';

final client = ConvexClient('https://your-deployment.convex.cloud');

final subscription = client.subscribe('messages:list', {'channel': 'general'});
subscription.stream.listen((result) {
  switch (result) {
    case QuerySuccess(:final value):
      print(value);
    case QueryError(:final message):
      print(message);
    case QueryLoading():
      break; // Cleared by an optimistic update; a concrete result follows.
  }
});

final current = await client.query('messages:list', {'channel': 'general'});
await client.mutate('messages:send', {'body': 'Hello'});
```

Use the deployment's `https://<name>.convex.cloud` URL; the `.convex.site`
host serves HTTP actions only and is rejected. One-shot `query()` /
`queryOnce()` always wait for a fresh server result. A live `subscribe()`
may start from the result kept after an earlier subscription to the same
query was cancelled; that seed has `fromCache: true` and can be stale until
the server answers. While offline one-shot reads wait for the reconnect
unless `ConvexClientConfig.queryTimeout` bounds the wait.

Outside widgets, `watch` gives a decoded `Stream<T>` that unsubscribes when
its listener cancels:

```dart
final messages = client.watch(
  'messages:list',
  {'channel': 'general'},
  decode: (value) => (value as List).cast<Map<String, dynamic>>(),
);
// The server's current value, never the cached seed:
final latest = await client
    .watch<List<dynamic>>('messages:list', {'channel': 'general'},
        skipCached: true)
    .first;
```

## Auth

Preferred mobile-style auth:

```dart
final authClient = client.withAuth(myAuthProvider);

authClient.authState.listen((state) {
  switch (state) {
    case AuthAuthenticated(:final userInfo):
      print(userInfo);
    case AuthLoading():
      print('Signing in...');
    case AuthUnauthenticated():
      print('Signed out');
  }
});

await authClient.login();
await authClient.loginFromCache();
await authClient.logout();
```

Low-level manual token auth remains available:

```dart
await client.setAuth('jwt-token');

final handle = await client.setAuthWithRefresh(
  fetchToken: ({required bool forceRefresh}) async {
    return obtainJwtFromYourAuthProvider(forceRefresh: forceRefresh);
  },
  onAuthChange: (isAuthenticated) => print(isAuthenticated),
);

await handle.cancel();
await client.clearAuth();
```

`onAuthChange(true)` fires once per auth flow, when the server first confirms
the token. Read the current state with `client.isAuthenticated` (the
`authState` stream does not replay) and the token in use — refreshed tokens
included — with `client.currentAuthToken` (also on `ConvexClientWithAuth`);
use it for `Authorization: Bearer ...` on Convex HTTP actions, since a
session object captured at login keeps the login-time token.

`setAuth`, `setAuthWithRefresh` and `clearAuth` start a new identity: live
queries report loading and discard previous results and optimistic layers
until the server confirms that identity. Use `updateAuthToken` for a renewed
token of the same user; refreshes preserve live results. With `dartvex_local`,
apply the new auth first, then `await local.reset()` to purge persisted data.

Auth-related configuration:

- `ConvexClientConfig(expectAuth: true)` holds every query, mutation, and
  action until the first `setAuth` / `setAuthWithRefresh` / `clearAuth`, so
  nothing runs unauthenticated during app start (call `clearAuth()` when the
  user is known to be signed out).
- `initialAuthTokenReuse` (experimental, default `false`) keeps a cached
  token that the server confirms instead of fetching a fresh one right away.
- `authTokenType` is `'User'` (default) or `'Admin'`; other values throw.

### Deployment-issued JWTs

A Convex mutation can mint short-lived tokens with `ctx.auth.signJwt` (an
ES256 JWT whose issuer is the deployment's `CONVEX_CLOUD_URL`, lifetime at
most 1 hour), so an app can authenticate with a credential your backend
verifies itself — no external identity provider. Trust the deployment as a
`customJwt` provider in `auth.config.ts` (`issuer: CONVEX_CLOUD_URL`,
`jwks: <CONVEX_CLOUD_URL>/.well-known/jwks.json`, `algorithm: "ES256"`), then
let `setAuthWithRefresh` call the mutation. Mint tokens on a separate,
unauthenticated client, because the authenticated one pauses its socket
while it refreshes a rejected token:

```dart
final tokenClient = ConvexClient('https://your-deployment.convex.cloud');
await client.setAuthWithRefresh(
  fetchToken: ({required bool forceRefresh}) async =>
      await tokenClient.mutate('session:issueToken', {
        'credential': credential,
      }) as String,
);
```

The `dartvex-setup-auth` agent skill in the repository has the full
backend recipe.

## One-shot Query

For non-reactive reads (splash screen, config loading), use `queryOnce<T>()`:

```dart
final config = await client.queryOnce<Map<String, dynamic>>('settings:get');
final userName = await client.queryOnce<String>('users:getName', {'id': userId});
```

## Convex Values

Use Dart `int` or `double` for Convex `v.number()` arguments:

```dart
await client.mutate('scores:set', {'score': 42, 'ratio': 0.5});
```

Use `convexInt64(value)` or `BigInt.from(value)` for Convex `v.int64()`
arguments. Convex int64 results decode as `BigInt`.

```dart
await client.mutate('counters:set', {'count': convexInt64(42)});

final count = await client.queryOnce<BigInt>('counters:get');
```

Plain Dart `int` values intentionally stay JSON numbers so `v.number()` calls
continue to work as expected. An `int` beyond ±2^53 that a float64 cannot
represent exactly throws an `ArgumentError` instead of silently changing;
pass such values as `BigInt` (`v.int64()`).

`Uint8List` maps to `v.bytes()`. A mutation's unresolved commit timestamp
(`{"$commitTs": null}`, convex 1.43+) decodes to
`ConvexCommitTsPlaceholder.instance` and encodes back unchanged.

## Query Errors

Subscription errors expose the human-readable message plus optional structured
Convex error data and server log lines:

```dart
subscription.stream.listen((result) {
  switch (result) {
    case QuerySuccess(:final value):
      print(value);
    case QueryError(:final message, :final data, :final logLines):
      print(message);
      print(data);
      print(logLines);
    case QueryLoading():
      break;
  }
});
```

One-shot `query()` and `queryOnce<T>()` failures throw `ConvexException` with
the same `message`, `data`, and `logLines` fields.

## File Storage

Upload and download files using `ConvexStorage`:

```dart
final storage = ConvexStorage(client);

// Upload
final storageId = await storage.uploadFile(
  uploadUrlAction: 'files:generateUploadUrl', // a mutation by default
  bytes: imageBytes,
  contentType: 'image/jpeg',
  filename: 'photo.jpg', // optional, only used in debug logs
  timeout: const Duration(minutes: 2), // optional, bounds the upload POST
  // useAction: true, // when the upload URL comes from an action
);

// Get download URL
final url = await storage.getFileUrl(
  getUrlAction: 'files:getUrl',
  storageId: storageId,
);
```

Small files can skip the upload URL: Convex mutations can call
`ctx.storage.store(new Blob([bytes]))`, so pass the `Uint8List` as a
`v.bytes()` argument to a mutation that stores the file and records it in one
transaction. Function-argument size limits apply, so keep `uploadFile` for
larger files.

## Logging

`dartvex` is silent by default.

To enable structured diagnostic logs, configure `ConvexClientConfig`:

```dart
final client = ConvexClient(
  'https://your-deployment.convex.cloud',
  config: ConvexClientConfig(
    logLevel: DartvexLogLevel.info,
    logger: (event) {
      print('[${event.level.name}] ${event.tag}: ${event.message}');
    },
  ),
);
```

Recommended usage:

- `error`: request or transport failures
- `warn`: degraded behavior, retries, large or slow transitions
- `info`: lifecycle events
- `debug`: integration diagnostics

Sensitive values such as auth tokens should not be logged.

## Connection Control

By default, `ConvexClient` opens its WebSocket when constructed. Set
`connectImmediately: false` to defer the connection until the first backend
operation, auth update, or explicit reconnect:

```dart
final client = ConvexClient(
  'https://your-deployment.convex.cloud',
  config: const ConvexClientConfig(connectImmediately: false),
);

await client.reconnectNow('manual-refresh');
```

Dropped connections are retried with exponential backoff and jitter, classifying
server overload reasons to back off more conservatively. Tune the behavior — or
bound the handshake itself so a dead connection cannot hang on the platform TCP
timeout — via `ConvexClientConfig`:

```dart
final client = ConvexClient(
  'https://your-deployment.convex.cloud',
  config: const ConvexClientConfig(
    connectTimeout: Duration(seconds: 10),
    initialBackoff: Duration(seconds: 1),
    maxBackoff: Duration(seconds: 16),
    backoffJitter: 0.5,
  ),
);
```

To reconnect the instant the device regains connectivity instead of waiting out
the backoff, supply a `connectivitySignal`. Flutter apps can use
`ConnectivityPlusSignal` from `dartvex_flutter`.

`ConvexClient(url, onServerDisconnectError: (message) => ...)` is an
experimental telemetry hook that receives a description of each abnormal
server disconnect (mirrors the official client's unstable option).

## Optimistic Updates

Pass an `OptimisticUpdate` as the third argument to `mutate` to overlay query
results the instant the mutation is sent. The overlay is replayed whenever fresh
server data arrives while the mutation is pending, and is rolled back
automatically when the mutation completes (replaced by the authoritative result,
without flicker) or fails:

```dart
await client.mutate(
  'messages:send',
  {'channel': 'general', 'body': 'Hello'},
  (store) {
    final existing = store.getQuery('messages:list', {'channel': 'general'});
    final messages = existing is List ? List<dynamic>.from(existing) : <dynamic>[];
    messages.add({'_id': 'optimistic', 'body': 'Hello'});
    store.setQuery('messages:list', {'channel': 'general'}, messages);
  },
);
```

The update must be pure (it can be replayed multiple times). Read current values
with `store.getQuery(name, args)` / `store.getAllQueries(name)` and overlay new
ones with `store.setQuery(name, args, value)` — `null` is the real Convex `null`
value; use `store.clearQuery(name, args)` to clear a query to a loading state.

## Reactive Pagination

`paginatedQuery` drives a Convex paginated query (one taking `paginationOpts`)
as a growing, reactive list. Loaded pages update live and stay gapless across
reconnects via query journals:

```dart
final page = client.paginatedQuery(
  'messages:paginate',
  {'channel': 'general'},
  pageSize: 20,
);

page.stream.listen((result) {
  print('${result.results.length} items, status: ${result.status}');
});

if (!page.isDone) {
  page.loadMore();
}

// Restart from the first page (for example on pull-to-refresh).
page.reset();

// Release every page subscription when done.
page.cancel();
```

`ConvexPaginationStatus` reports `loadingFirstPage`, `loadingMore`,
`canLoadMore`, `exhausted`, or `error`. The query also restarts by itself
when the server reports an invalid cursor for a loaded page.

## Connection Status

`currentConnectionStatus` and the value-deduplicated `connectionStatus` stream
expose a rich `ConnectionStatus` snapshot — useful for loading and retry
indicators. The coarse `ConnectionState` enum and `connectionState` stream
remain available as a derived convenience:

```dart
client.connectionStatus.listen((status) {
  print('connected: ${status.isConnected}');     // socket up AND fully synced
  print('loading:   ${status.isLoading}');        // re-syncing after a reconnect
  print('inflight:  ${status.inflightMutations} mutations, '
      '${status.inflightActions} actions');
  print('retries:   ${status.connectionRetries}');
});
```

`ConnectionStatus` also carries `isWebSocketConnected`, `hasEverConnected`,
`connectionCount`, `timeOfOldestInflightRequest`, `hasInflightRequests`,
`hasSyncedPastLastReconnect`, and the derived coarse `state`. For an offline
indicator use `!isWebSocketConnected`: `isLoading` stays `false` while the
socket is down.

## Auth Refreshing

When auth is recovered after a server rejection, the socket briefly stops while a
fresh token is fetched. `isAuthRefreshing` and the `authRefreshing` stream report
this so you can show an "authenticating…" indicator instead of surfacing the
transient disconnect:

```dart
client.authRefreshing.listen((isRefreshing) {
  if (isRefreshing) showAuthenticatingBanner();
  else hideAuthenticatingBanner();
});
```

Flutter apps can use `ConvexAuthRefreshingBuilder` and
`ConvexConnectionStatusBuilder` from
[`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter).

## API Overview

### Core

| Class | Description |
|-------|-------------|
| `ConvexClient` | Main client — connect, subscribe, mutate, act |
| `ConvexClientConfig` | Configuration (client ID, timeouts, backoff, logging) |
| `ConvexSubscription` | Reactive subscription handle with stream |
| `QueryResult` | Base type for `QuerySuccess` / `QueryError` / `QueryLoading` |
| `ConnectionStatus` | Rich connection snapshot — inflight counts, retries, sync |
| `ConvexPaginatedQuery` | Reactive, gapless paginated query handle |
| `OptimisticLocalStore` | Overlay store passed to optimistic updates |
| `ConvexStorage` | File upload and URL generation |

### Auth

| Class | Description |
|-------|-------------|
| `ConvexClientWithAuth` | Client with integrated authentication |
| `ConvexAuthClient` | Auth-aware client wrapper |
| `AuthProvider` | Interface for auth adapters |
| `AuthState` | `AuthAuthenticated` / `AuthUnauthenticated` / `AuthLoading` |

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation, examples, and the Flutter widget package.
