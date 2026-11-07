---
name: dartvex-setup-offline
description: Add offline support to a dartvex Convex app with dartvex_local - SQLite query cache served when the network is down, offline mutation queue with ordered replay, and local optimistic patches for queued writes. Use when the user wants offline-first behavior, airplane-mode resilience, queued writes, or mentions dartvex_local.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.3.0"
---

# Offline Support with dartvex_local

`ConvexLocalClient` wraps a `ConvexClient` with a persistent SQLite query
cache and an offline mutation queue. Know the model before wiring it:

- **At-least-once replay** — queued mutations may retry after ambiguous
  network failures (or after a local storage failure followed by a restart).
  Mutations with external side effects must be idempotent.
- **No merge engine** — conflicts surface via `onConflict`; the app decides.
- **Not user-scoped** — the cache and queue belong to the device, not the
  signed-in user; call `reset()` on sign-out or user switch.
- **Native only out of the box** — bundled `SqliteLocalStore` uses
  `dart:io`. On web, implement `CacheStorage`/`QueueStorage` yourself.
- Requires Dart `>=3.10` (sqlite3 dependency floor).

## Setup

```yaml
dependencies:
  dartvex: ^0.3.0
  dartvex_local: ^0.3.0
  path_provider: ^2.1.0 # Flutter: an app-support directory for the database
```

```dart
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:path_provider/path_provider.dart';

final remote = ConvexClient(deploymentUrl);

// A persistent, app-private location: never a relative path (the working
// directory is `/` on iOS/Android) and never a temp dir (the queue would be
// lost on reboot).
final dir = await getApplicationSupportDirectory();
final store = await SqliteLocalStore.open('${dir.path}/dartvex.sqlite');

final localClient = await ConvexLocalClient.open(
  client: remote,
  config: LocalClientConfig(
    cacheStorage: store,
    queueStorage: store,
    mutationHandlers: <LocalMutationHandler>[SendMessageHandler()],
    // Pass onConflict here: replay can start while the client opens.
    onConflict: (conflict) => print('dropped: ${conflict.mutationName}'),
  ),
);
```

Apply auth to the `ConvexClient` (`login`/`loginFromCache`) before, or right
after, `open`, so replay does not run unauthenticated.

## Behavior matrix

"Offline" below means the remote is not connected (still connecting,
reconnecting, or down — `currentConnectionState` is then `offline`) or the
client is forced offline with `setNetworkMode(LocalNetworkMode.offline)`.

| Scenario | Behavior |
|----------|----------|
| `query()` while connected | Remote result (cached); a retryable failure falls back to the cache |
| `query()` while not connected | Cached value right away; with no cache, waits up to `refreshQueryTimeout` (default 5 s) for the remote, then throws `TimeoutException` |
| `query()` while forced offline, no cache | Throws `StateError` |
| `subscribe()` | Seeded from the cache, then live remote updates while connected |
| `mutate()` while connected, queue empty | Sent directly → `LocalMutationSuccess`, or `LocalMutationFailed` for a server rejection (no handler patch) |
| `mutate()` while offline or behind queued mutations | Queued → `LocalMutationQueued`; handler patches applied; replayed in order on reconnect |
| Replay rejected by the server | Dropped, patches rolled back, `onConflict` called |
| `action()` while forced offline | Throws `ConvexException` (actions are never queued) |
| `action()` while merely disconnected | Waits in the core client and is sent after the reconnect |

## Use it from Flutter

`ConvexProvider` takes a `ConvexRuntimeClient`, which `ConvexLocalClient`
does not implement (it is pure Dart, and its `mutate` returns a
`LocalMutationResult`). Either use the local client directly:

```dart
final sub = localClient.subscribe('messages:list', {'channel': 'general'});
sub.stream.listen((event) {
  switch (event) {
    case LocalQuerySuccess(:final value, :final source, :final hasPendingWrites):
      render(value, fromCache: source == LocalQuerySource.cache,
          pending: hasPendingWrites);
    case LocalQueryError(:final error):
      showError(error);
  }
});
// Later: sub.cancel();
```

or wrap it in a small adapter so `ConvexQuery`/`ConvexMutation` work
unchanged: copy `LocalConvexRuntimeClient` from the example app
(`example/flutter_app/lib/src/core/local_runtime_client.dart` in the Dartvex
repo) and pass it to `ConvexProvider(client: LocalConvexRuntimeClient(localClient))`.
It maps `LocalQueryEvent`s to runtime events and `LocalConnectionState` to
`ConvexConnectionState`; it does not support `PaginatedQueryBuilder`, and its
`mutate` resolves with the `LocalMutationResult` (use `ConvexMutation<dynamic>`
or `ConvexMutation<LocalMutationResult>` with it). Generated `ConvexApi`
bindings cannot wrap the local client — typed calls through the
`ConvexClient` bypass the cache and queue.

## mutate() returns a result — it does not throw for server errors

```dart
final result = await localClient.mutate('messages:send', {
  'channel': 'general',
  'body': 'Hello',
});
switch (result) {
  case LocalMutationSuccess(:final value):
    print('saved: $value');
  case LocalMutationQueued(:final queuePosition):
    print('queued (#$queuePosition), will sync later');
  case LocalMutationFailed(:final error):
    showError(error); // e.g. a server validation error
}
```

`mutate()` only throws when queueing itself fails locally (a throwing
handler or patch, a storage error). Calls are serialized in FIFO order. A
queued mutation the server later rejects is reported through `onConflict`,
not through this result.

## Local optimistic patches — LocalMutationHandler

Handlers patch the *cache* when a mutation is **queued** (offline, behind
other queued mutations, or after a retryable failure of the direct send), so
the UI reflects the write before it reaches the server. A mutation sent
directly while online is not patched; for instant feedback on that path,
use the core client's optimistic updates (`ConvexClient.mutate(name, args,
optimisticUpdate)`).

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
        target: LocalQueryDescriptor(
          'messages:list',
          {'channel': args['channel']},
        ),
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

Patches must be pure (replayable). The target must match the cached query's
name **and** arguments. Several handlers can be registered for one mutation
(applied in registration order); names match canonically (`messages.js:send`
equals `messages:send`). On rollback (replay drop/failure) the cache is
restored automatically.

## Forcing offline (testing and user toggle)

```dart
await localClient.setNetworkMode(LocalNetworkMode.offline);
// … later, back to following real connectivity (the default):
await localClient.setNetworkMode(LocalNetworkMode.auto);
```

There are only these two modes: `auto` follows the real connection, and
`offline` forces offline. There is no forced-online mode. Forcing offline is
deterministic regardless of actual connectivity — use it in tests to
exercise the queue and replay paths. Watch `connectionState` /
`pendingMutations` streams for UI indicators (`syncing` while the queue
replays).

## Sign-out and switching users

```dart
await authedClient.logout();
await localClient.reset(); // queue (rolled back), ID remaps, then cache
```

The client never clears anything on its own when auth changes, so a
transient token-refresh failure does not discard offline work.

## Cache policy

By default nothing is evicted until `clearCache()` (or `reset()`). Configure
`LocalClientConfig.queryCachePolicy` to expire stale entries and cap the
SQLite cache to a maximum entry count.

## Verify

1. Load a screen online (populates the cache).
2. Force offline; relaunch the screen — data serves from cache.
3. Issue a mutation offline — it returns `LocalMutationQueued` and the UI
   updates via the handler patch.
4. Go online — the queue replays in order; server state converges.
5. Sign out — after `reset()` the next user sees no cached data.

## Common mistakes

- Non-idempotent server mutations with external side effects (emails,
  payments) — at-least-once replay can run them twice. Make them idempotent
  or keep them out of the offline path.
- Opening the SQLite file at a relative path or in a temp dir — use an
  app-support/documents directory so the queue survives restarts.
- `try { await localClient.mutate(...) } catch` — server errors arrive as
  `LocalMutationFailed`, not exceptions.
- Expecting handler patches while online — they only apply to queued
  mutations.
- Expecting actions to queue offline — they never do.
- Forgetting `reset()` on sign-out — the next user would see cached data and
  replay the previous user's queue.
- Custom web stores: `CacheStorage.deleteCacheEntry` must physically remove
  single entries, `QueueStorage` must persist failed locally-generated IDs,
  and `QueueStorage` must apply writes in call order even when several are in
  flight — all are required for correct rollback/replay.
