<p align="center">
  <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
</p>

# dartvex

Pure Dart client for [Convex](https://convex.dev) with WebSocket sync, type-safe values, and reactive subscriptions. Works on iOS, Android, web, and desktop.

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| **[`dartvex`](https://pub.dev/packages/dartvex)** | Core client — WebSocket sync, subscriptions, auth |
| [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) | Flutter widgets — Provider, QueryBuilder, MutationBuilder |
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
- Auth framework with pluggable `AuthProvider<T>` abstraction
- One-shot query via `queryOnce<T>()` for non-reactive reads
- File storage helpers via `ConvexStorage` (upload/download)
- Reconnection with exponential backoff and full query set rebuild
- Native and browser WebSocket adapters (conditional import)
- Structured opt-in logging for transport, auth, and storage diagnostics

## Platform Support

| Platform | Transport | Status |
|----------|-----------|--------|
| iOS / Android | `dart:io` WebSocket | Tested |
| macOS / Linux / Windows | `dart:io` WebSocket | Tested |
| Web (JS / Wasm) | `package:web` WebSocket | Builds, not yet browser-tested |

The web adapter is selected automatically via conditional import.

## Installation

```yaml
dependencies:
  dartvex: ^0.1.3
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

## API Overview

### Core

| Class | Description |
|-------|-------------|
| `ConvexClient` | Main client — connect, subscribe, mutate, act |
| `ConvexClientConfig` | Configuration (deployment URL, client ID) |
| `ConvexSubscription` | Reactive subscription handle with stream |
| `QueryResult` | Base type for `QuerySuccess` / `QueryError` |
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
