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
| [`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen) | CLI code generator — type-safe Dart bindings from schema |
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

## Platform Support

| Platform | Transport | Status |
|----------|-----------|--------|
| iOS / Android | `dart:io` WebSocket | Tested |
| macOS / Linux / Windows | `dart:io` WebSocket | Tested |
| Web (JS / Wasm) | `package:web` WebSocket | Tested |

The web adapter is selected automatically via conditional import.

## Installation

```yaml
dependencies:
  dartvex: ^0.2.0
```

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
  }
});

final current = await client.query('messages:list', {'channel': 'general'});
await client.mutate('messages:send', {'body': 'Hello'});
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
continue to work as expected.

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
  uploadUrlAction: 'files:generateUploadUrl',
  bytes: imageBytes,
  filename: 'photo.jpg',
  contentType: 'image/jpeg',
);

// Get download URL
final url = await storage.getFileUrl(
  getUrlAction: 'files:getUrl',
  storageId: storageId,
);
```

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
ones with `store.setQuery(name, args, value)` — pass `null` to remove a query.

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

// Release every page subscription when done.
page.cancel();
```

`ConvexPaginationStatus` reports `loadingFirstPage`, `loadingMore`,
`canLoadMore`, `exhausted`, or `error`.

## Connection Status

`currentConnectionStatus` and the value-deduplicated `connectionStatus` stream
expose a rich `ConnectionStatus` snapshot — useful for loading and retry
indicators. The coarse `ConnectionState` enum and `connectionState` stream
remain available as a derived convenience:

```dart
client.connectionStatus.listen((status) {
  print('connected: ${status.isConnected}');     // socket up AND fully synced
  print('loading:   ${status.isLoading}');        // not yet re-synced
  print('inflight:  ${status.inflightMutations} mutations, '
      '${status.inflightActions} actions');
  print('retries:   ${status.connectionRetries}');
});
```

`ConnectionStatus` also carries `isWebSocketConnected`, `hasEverConnected`,
`connectionCount`, `timeOfOldestInflightRequest`, `hasInflightRequests`, and the
derived coarse `state`.

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
| `QueryResult` | Base type for `QuerySuccess` / `QueryError` |
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
