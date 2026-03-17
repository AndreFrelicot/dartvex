# dartvex_flutter

Flutter widgets and builders for [dartvex](../dartvex/).

`dartvex_flutter` removes the repetitive widget lifecycle code around realtime
Convex subscriptions, mutations, actions, and connection state. The package is
designed around a small runtime interface so a future local-first adapter can
plug into the same widgets without breaking the public API.

## Features

- `ConvexQuery` — reactive query widget with automatic subscription management
- `ConvexMutation` / `ConvexAction` — request builder widgets
- `ConvexImage` — display images from Convex file storage
- `PaginatedQueryBuilder` — cursor-based pagination with load-more
- `ConvexAuthProvider` / `ConvexAuthBuilder` — auth state widgets
- `ConvexConnectionBuilder` / `ConvexConnectionIndicator` — connection status
- `ConvexOfflineImage` / `ConvexAssetCache` — offline binary asset caching
- `FakeConvexClient` — test helper for unit and widget tests
- Runtime-interface based — works with `ConvexClientRuntime` and local-first adapters

## Installation

```yaml
dependencies:
  dartvex: ^0.1.0
  dartvex_flutter: ^0.1.0
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

## Pagination

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

## API Overview

| Widget | Description |
|--------|-------------|
| `ConvexProvider` | Provides client to widget tree via InheritedWidget |
| `ConvexQueryBuilder` | Reactive query with automatic re-rendering |
| `ConvexMutationBuilder` | Mutation trigger with loading/error state |
| `ConvexActionBuilder` | Action trigger with loading/error state |
| `PaginatedQueryBuilder` | Cursor-based paginated query |
| `ConvexAuthBuilder` | Renders based on auth state |
| `ConvexConnectionBuilder` | Renders based on connection state |
| `ConvexImage` | Image from Convex storage |
| `ConvexOfflineImage` | Offline-capable image with caching |
| `FakeConvexClient` | Test double for widget tests |

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
