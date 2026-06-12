---
name: dartvex-setup-offline
description: Add offline support to a dartvex Convex app with dartvex_local - SQLite query cache served when the network is down, offline mutation queue with ordered replay, and local optimistic patches. Use when the user wants offline-first behavior, airplane-mode resilience, queued writes, or mentions dartvex_local.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Offline Support with dartvex_local

`ConvexLocalClient` wraps a `ConvexClient` with a persistent SQLite query
cache and an offline mutation queue. Know the model before wiring it:

- **At-least-once replay** — queued mutations may retry after ambiguous
  network failures. Mutations with external side effects must be idempotent.
- **No merge engine** — conflicts surface via `onConflict`; the app decides.
- **Native only out of the box** — bundled `SqliteLocalStore` uses
  `dart:io`. On web, implement `CacheStorage`/`QueueStorage` yourself.
- Requires Dart `>=3.10` (sqlite3 dependency floor).

## Setup

```yaml
dependencies:
  dartvex: ^0.2.0
  dartvex_local: ^0.2.0
```

```dart
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';

final remote = ConvexClient(deploymentUrl);

// Use a real app-documents path in production (e.g. path_provider).
final store = await SqliteLocalStore.open('/path/to/app/dartvex.sqlite');

final localClient = await ConvexLocalClient.open(
  client: remote,
  config: LocalClientConfig(
    cacheStorage: store,
    queueStorage: store,
    mutationHandlers: <LocalMutationHandler>[SendMessageHandler()],
  ),
);
```

Behavior matrix:

| Scenario | Behavior |
|----------|----------|
| Remote query fails (retryable) | Falls back to cache if available |
| Query while offline, no cache | Throws `StateError` |
| Mutation while offline | Queued (`LocalMutationQueued`), replayed in order on reconnect |
| Replay fails (non-retryable) | Dropped; `onConflict` called |
| Action while offline | Throws `ConvexException` (actions are never queued) |

## Local optimistic patches — LocalMutationHandler

Handlers patch the *cache* immediately when a mutation is issued (online or
offline), so the UI reflects the write before the server confirms:

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
          // context.operationId is a locally-generated ID; when the server
          // later assigns a real document ID, dependent queued mutations
          // are remapped automatically.
          list.add({'_id': context.operationId, ...args});
          return list;
        },
      ),
    ];
  }
}
```

Patches must be pure (replayable). On rollback (replay drop/failure) the
cache is restored automatically.

## Forcing offline (testing and user toggle)

```dart
await localClient.setNetworkMode(LocalNetworkMode.offline);
// … later, back to following real connectivity (the default):
await localClient.setNetworkMode(LocalNetworkMode.auto);
```

(`LocalNetworkMode.online` forces online regardless of connectivity.)

This is deterministic regardless of actual connectivity — use it in tests
to exercise the queue and replay paths.

## Cache policy

By default nothing is evicted until `clearCache()`. Configure
`LocalClientConfig.queryCachePolicy` to expire stale entries and cap the
SQLite cache to a maximum entry count.

## Verify

1. Load a screen online (populates the cache).
2. Force offline; relaunch the screen — data serves from cache.
3. Issue a mutation offline — UI updates via the handler patch; the
   mutation shows as queued.
4. Go online — the queue replays in order; server state converges.

## Common mistakes

- Non-idempotent server mutations with external side effects (emails,
  payments) — at-least-once replay can run them twice. Make them idempotent
  or keep them out of the offline path.
- Opening the SQLite file in a temp dir — use an app-documents directory so
  the queue survives restarts.
- Expecting actions to queue offline — they never do.
- Custom web stores: `CacheStorage.deleteCacheEntry` must physically remove
  single entries, and `QueueStorage` must persist failed locally-generated
  IDs — both are required for correct rollback/replay.
