<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
  </a>
</p>

# dartvex_flutter

Flutter widgets and builders for [dartvex](https://pub.dev/packages/dartvex) — the pure Dart client for [Convex](https://convex.dev).

`dartvex_flutter` removes the repetitive widget lifecycle code around realtime
Convex subscriptions, mutations, actions, and connection state. The package is
designed around a small runtime interface so a future local-first adapter can
plug into the same widgets without breaking the public API.

<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-poster.webp" width="900" alt="Dartvex Flutter demo — real-time chats running on iOS and macOS" />
  </a>
</p>

## The Dartvex ecosystem

| Package | Description |
|---------|-------------|
| [`dartvex`](https://pub.dev/packages/dartvex) | Core client — WebSocket sync, subscriptions, auth |
| **[`dartvex_flutter`](https://pub.dev/packages/dartvex_flutter)** | Flutter widgets — Provider, Query, Mutation |
| [`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen) | CLI code generator — type-safe Dart bindings from schema |
| [`dartvex_local`](https://pub.dev/packages/dartvex_local) | Offline support — SQLite cache, mutation queue |
| [`dartvex_auth_better`](https://pub.dev/packages/dartvex_auth_better) | Better Auth adapter |

Source and full docs: [github.com/AndreFrelicot/dartvex](https://github.com/AndreFrelicot/dartvex)

## Features

- `ConvexQuery` — reactive query widget with automatic subscription management
- `ConvexMutation` / `ConvexAction` — request builder widgets, with optional
  optimistic updates on `ConvexMutation`
- `ConvexImage` — native image display from Convex file storage
- `ConvexCachedImage` — native Convex storage images with persistent disk caching
- `PaginatedQueryBuilder` — cursor-based, reactive gapless pagination with load-more
- `ConvexAuthProvider` / `ConvexAuthBuilder` — auth state widgets
- `ConvexConnectionBuilder` / `ConvexConnectionIndicator` — coarse connection status
- `ConvexConnectionStatusBuilder` — rich connection status (inflight, retries, loading)
- `ConvexAuthRefreshingBuilder` — auth-refreshing indicator
- `ConvexOfflineImage` / `ConvexAssetCache` — native offline binary asset caching
- `FakeConvexClient` — test helper for unit and widget tests
- App lifecycle reconnect when a Flutter app resumes while disconnected
- Runtime-interface based — works with `ConvexClientRuntime` and local-first adapters

The core storage flow works on web: resolve a signed storage URL and render it
with `Image.network`. The `ConvexImage`, `ConvexCachedImage`,
`ConvexOfflineImage`, and `ConvexAssetCache` helpers are native-only because
they use `dart:io` and `flutter_cache_manager` for streaming downloads and disk
cache/offline fallback.

## Installation

```yaml
dependencies:
  dartvex: ^0.2.0
  dartvex_flutter: ^0.2.0
```

## Provider Setup

```dart
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';

final client = ConvexClient('https://your-deployment.convex.cloud');
final runtime = ConvexClientRuntime(client);

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return ConvexProvider(
      client: runtime,
      child: const MyApp(),
    );
  }
}
```

To reconnect immediately when the device regains connectivity, pass a
`ConnectivityPlusSignal` into the client configuration:

```dart
final client = ConvexClient(
  'https://your-deployment.convex.cloud',
  config: ConvexClientConfig(
    connectivitySignal: ConnectivityPlusSignal(),
  ),
);
```

## Auth Widgets

```dart
final authedClient = client.withAuth(myAuthProvider);

ConvexAuthProvider<MyUser>(
  client: authedClient,
  child: ConvexAuthBuilder<MyUser>(
    builder: (context, state) {
      return switch (state) {
        AuthLoading<MyUser>() => const CircularProgressIndicator(),
        AuthAuthenticated<MyUser>(:final userInfo) => Text(userInfo.name),
        AuthUnauthenticated<MyUser>() => const Text('Signed out'),
      };
    },
  ),
)
```

## Query Widget

```dart
ConvexQuery<List<Message>>(
  query: 'messages:list',
  args: const {'channel': 'general'},
  decode: (value) => decodeMessages(value),
  builder: (context, snapshot) {
    if (snapshot.isLoading) return const CircularProgressIndicator();
    if (snapshot.hasError) return Text(snapshot.error.toString());
    final messages = snapshot.data ?? const <Message>[];
    return ListView(
      children: [for (final message in messages) Text(message.text)],
    );
  },
)
```

## Mutation Widget

```dart
ConvexMutation<String>(
  mutation: 'messages:send',
  builder: (context, mutate, snapshot) {
    return FilledButton(
      onPressed: snapshot.isLoading
          ? null
          : () => mutate({'author': 'Flutter User', 'text': 'Hello'}),
      child: Text(snapshot.isLoading ? 'Sending...' : 'Send'),
    );
  },
)
```

## Cached Images

> Disk-backed image cache is not supported on Flutter web. For web builds,
> resolve a signed storage URL and render it with `Image.network`; keep
> `ConvexCachedImage`, `ConvexOfflineImage`, and `ConvexAssetCache` for native
> targets.

```dart
ConvexCachedImage(
  storageId: message.imageStorageId,
  getUrlAction: 'files:getUrl',
  useAction: true,
  width: 160,
  height: 160,
  fit: BoxFit.cover,
)
```

`ConvexImage` and `ConvexCachedImage` resolve storage URLs with a Convex query
by default. Set `useAction: true` when the resolver is implemented as an action.
Both widgets are native-only in this release; on web, use the same resolver and
pass the returned URL to `Image.network`.

## Pagination

`PaginatedQueryBuilder` is backed by the core reactive pagination engine: loaded
pages update live as their data changes and stay gapless at page boundaries. Its
public API (`query` / `builder` / `fromJson` / `args` / `pageSize` / `client`)
and `PaginationStatus` are unchanged.

```dart
PaginatedQueryBuilder<Message>(
  query: 'messages:list',
  args: const {'status': 'active'},
  pageSize: 20,
  fromJson: Message.fromJson,
  builder: (context, items, loadMore, status) {
    return ListView.builder(
      itemCount: items.length + (status == PaginationStatus.allLoaded ? 0 : 1),
      itemBuilder: (_, i) => i < items.length
        ? MessageTile(items[i])
        : TextButton(onPressed: loadMore, child: const Text('Load more')),
    );
  },
)
```

## Testing

```dart
final client = FakeConvexClient()
  ..whenQuery('messages:list', returns: [mockMessage1, mockMessage2])
  ..whenMutation('messages:send', returns: {'id': 'xxx'});

await tester.pumpWidget(
  ConvexProvider(client: client, child: MyApp()),
);
```

## Optimistic Mutations

Pass an `OptimisticUpdate` to `ConvexMutation` to overlay query results the
instant the mutation is sent; it rolls back automatically when the mutation
completes or fails:

```dart
ConvexMutation<String>(
  mutation: 'messages:send',
  optimisticUpdate: (store) {
    final existing = store.getQuery('messages:list', const {'channel': 'general'});
    final messages = existing is List ? List<dynamic>.from(existing) : <dynamic>[];
    messages.add({'_id': 'optimistic', 'text': 'Hello'});
    store.setQuery('messages:list', const {'channel': 'general'}, messages);
  },
  builder: (context, mutate, snapshot) {
    return FilledButton(
      onPressed: () => mutate({'channel': 'general', 'text': 'Hello'}),
      child: const Text('Send'),
    );
  },
)
```

## Connection Status

`ConvexConnectionStatusBuilder` rebuilds on the rich `ConnectionStatus` (inflight
counts, retries, `hasEverConnected`, loading). The coarse `ConvexConnectionBuilder`
and `ConvexConnectionIndicator` are unchanged.

```dart
ConvexConnectionStatusBuilder(
  builder: (context, status) {
    if (status.isLoading) return const Text('Syncing…');
    if (!status.isWebSocketConnected) {
      return Text('Reconnecting (attempt ${status.connectionRetries})');
    }
    return Text('Online — ${status.inflightMutations} pending');
  },
)
```

## Auth Refreshing

`ConvexAuthRefreshingBuilder` rebuilds with the client's auth-refreshing state
(`true` while auth is being recovered after a server rejection), so you can show
an indicator instead of surfacing the brief disconnect:

```dart
ConvexAuthRefreshingBuilder(
  builder: (context, isRefreshing) {
    return isRefreshing
        ? const LinearProgressIndicator()
        : const SizedBox.shrink();
  },
)
```

## API Overview

| Widget | Description |
|--------|-------------|
| `ConvexProvider` | Provides client to widget tree via InheritedWidget |
| `ConvexQuery` | Reactive query with automatic re-rendering |
| `ConvexMutation` | Mutation trigger with loading/error state and optimistic updates |
| `ConvexAction` | Action trigger with loading/error state |
| `PaginatedQueryBuilder` | Cursor-based reactive gapless paginated query |
| `ConvexAuthBuilder` | Renders based on auth state |
| `ConvexAuthRefreshingBuilder` | Renders based on auth-refreshing state |
| `ConvexConnectionBuilder` | Renders based on coarse connection state |
| `ConvexConnectionStatusBuilder` | Renders based on rich connection status |
| `ConvexImage` | Native image from Convex storage |
| `ConvexCachedImage` | Native disk-cached image from Convex storage |
| `ConvexOfflineImage` | Native offline-capable image with caching |
| `FakeConvexClient` | Test double for widget tests |

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
