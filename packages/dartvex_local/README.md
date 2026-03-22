# dartvex_local

Offline-capable extension for [dartvex](../dartvex/). SQLite query cache and mutation queue with optimistic updates.

## What it does

- **Query cache** — remote query results are persisted in SQLite and served
  as fallback when the remote is unreachable or slow.
- **Offline mutation queue** — mutations issued while offline are queued and
  replayed in order when connectivity resumes.
- **Optimistic updates** — app-defined `LocalMutationHandler` patches are
  applied to the cache immediately, before the mutation reaches the server.
- **Deterministic network mode** — `setNetworkMode(offline)` forces the
  client offline regardless of actual connectivity.

## What it does NOT do

- No CRDTs or conflict-free merge engine. Conflicts are surfaced via the
  `onConflict` callback — the app decides what to do.
- No automatic cache eviction. Once cached, results stay until `clearCache()`.
- No web support. SQLite requires native `dart:io` targets.

## Installation

```yaml
dependencies:
  dartvex: ^0.1.3
  dartvex_local: ^0.1.1
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
| `QueryCache` | In-memory + persistent query cache |
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
