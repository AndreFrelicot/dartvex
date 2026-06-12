<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
  </a>
</p>

# dartvex_local

Offline-capable extension for [dartvex](https://pub.dev/packages/dartvex) — the pure Dart client for [Convex](https://convex.dev). SQLite query cache and mutation queue with optimistic updates.

<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-poster.webp" width="900" alt="Dartvex Flutter demo — real-time chats running on iOS and macOS" />
  </a>
</p>

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| [`dartvex`](https://pub.dev/packages/dartvex) | Core client — WebSocket sync, subscriptions, auth |
| [`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter) | Flutter widgets — Provider, Query, Mutation |
| [`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen) | CLI code generator — type-safe Dart bindings from schema |
| **[`dartvex_local`](https://pub.dev/packages/dartvex_local)** | Offline support — SQLite cache, mutation queue |
| [`dartvex_auth_better`](https://pub.dev/packages/dartvex_auth_better) | Better Auth adapter |

Source and full docs: [github.com/AndreFrelicot/dartvex](https://github.com/AndreFrelicot/dartvex)

## What it does

- **Query cache** — remote query results are persisted in SQLite and served
  as fallback when the remote is unreachable or slow.
- **Offline mutation queue** — mutations issued while offline are queued and
  replayed in order when connectivity resumes.
- **At-least-once replay** — queued mutations can be retried after ambiguous
  network failures, so server mutations should be idempotent when they trigger
  external side effects.
- **Optimistic updates** — app-defined `LocalMutationHandler` patches are
  applied to the cache immediately, before the mutation reaches the server.
- **Deterministic network mode** — `setNetworkMode(offline)` forces the
  client offline regardless of actual connectivity.

## What it does NOT do

- No CRDTs or conflict-free merge engine. Conflicts are surfaced via the
  `onConflict` callback — the app decides what to do.
- No automatic cache eviction by default. Results stay until `clearCache()`
  unless you configure `LocalClientConfig.queryCachePolicy`, which can expire
  stale entries and cap the SQLite cache to a maximum entry count.
- No bundled web storage. The included `SqliteLocalStore` requires native
  `dart:io` targets; on web, supply your own `CacheStorage`/`QueueStorage`.

## Platform Support

| Platform | Status |
|----------|--------|
| iOS / Android | Supported with native SQLite |
| macOS / Linux / Windows | Supported with native SQLite |
| Web | Bundled `SqliteLocalStore` unavailable — supply a custom store |

> **Requirements:** `dartvex_local` requires Dart **≥ 3.10** — its `sqlite3`
> dependency sets that floor. The other Dartvex packages have their own
> package-specific Dart and Flutter floors; check each package's `pubspec.yaml`
> or README before pinning a shared SDK floor.
>
> The bundled `SqliteLocalStore` is native-only (`dart:io`). To run
> `ConvexLocalClient` on the web, implement the `CacheStorage` and
> `QueueStorage` interfaces yourself (for example over IndexedDB) and pass them
> in `LocalClientConfig`. `CacheStorage.deleteCacheEntry` must physically remove
> a single entry so optimistic rollback and cache expiry stay correct.
> `QueueStorage` must also persist failed locally-generated IDs so replay can
> keep dependent mutations from being sent with stale IDs after a restart.

## Installation

```yaml
dependencies:
  dartvex: ^0.2.0
  dartvex_local: ^0.2.0
```

## Quick Start

```dart
import 'package:dartvex_local/dartvex_local.dart';

final store = await SqliteLocalStore.open('/tmp/dartvex_demo.sqlite');

final localClient = await ConvexLocalClient.open(
  client: remoteConvexClient,
  config: LocalClientConfig(
    cacheStorage: store,
    queueStorage: store,
    mutationHandlers: <LocalMutationHandler>[],
  ),
);
```

## Mutation Handlers

```dart
class SendMessageHandler extends LocalMutationHandler {
  @override
  String get mutationName => 'messages:send';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return [
      LocalMutationPatch(
        target: const LocalQueryDescriptor('messages:list'),
        apply: (currentValue) {
          final list = currentValue is List
              ? List<dynamic>.from(currentValue)
              : <dynamic>[];
          list.add({'_id': context.operationId, ...args});
          return list;
        },
      ),
    ];
  }
}
```

## API Overview

| Class | Description |
|-------|-------------|
| `ConvexLocalClient` | Offline-aware client with cache and queue |
| `QueryCache` | Persistent query cache with expiry/pruning policy |
| `MutationQueue` | Pending mutation queue with retry |
| `SqliteLocalStore` | SQLite-backed local storage |
| `PendingMutation` | Queued mutation with status tracking |

## Error Behavior

| Scenario | Behavior |
|----------|----------|
| Remote query fails (retryable) | Falls back to cache if available |
| Query while offline, no cache | Throws `StateError` |
| Mutation while offline | Queued as `LocalMutationQueued` |
| Mutation replay fails (non-retryable) | Dropped, `onConflict` called |
| Action while offline | Throws `ConvexException` |

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
