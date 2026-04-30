<p align="center">
  <img src="assets/dartvex-logo.svg" width="200" alt="Dartvex Logo" />
</p>

<h1 align="center">Dartvex</h1>

<p align="center">
  Pure Dart SDK for <a href="https://convex.dev">Convex</a> — real-time sync, type-safe codegen, Flutter widgets, and offline support.
</p>

<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex/actions/workflows/ci.yml"><img src="https://github.com/AndreFrelicot/dartvex/actions/workflows/ci.yml/badge.svg?branch=main&event=push" alt="CI" /></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://dart.dev"><img src="https://img.shields.io/badge/dart-%5E3.6.0-blue.svg" alt="Dart ^3.6.0" /></a>
  <a href="https://pub.dev/publishers/andrefrelicot.dev/packages"><img src="https://img.shields.io/badge/pub.dev-andrefrelicot.dev-0175C2" alt="pub.dev publisher: andrefrelicot.dev" /></a>
</p>

---

## Why Dartvex?

- **Pure Dart** — No Rust FFI, no native bridges. Works everywhere Dart runs.
- **Type-safe codegen** — Generate Dart bindings from your Convex schema. Catch errors at compile time.
- **Flutter widgets** — `ConvexProvider`, `ConvexQuery`, `ConvexMutation` and more for reactive UI.
- **Offline capable** — SQLite query cache and mutation queue with optimistic updates.
- **Multi-platform** — iOS, Android, web, macOS, Linux, Windows.

## Quick Start

```dart
import 'package:dartvex/dartvex.dart';

void main() async {
  final client = ConvexClient('https://your-deployment.convex.cloud');

  // Subscribe to a query
  final sub = client.subscribe('messages:list', {});
  sub.stream.listen((result) {
    if (result case QuerySuccess(:final value)) {
      print('Messages: $value');
    }
  });

  // Run a mutation
  await client.mutate('messages:send', {'body': 'Hello from Dart!'});
}
```

## Packages

| Package | Description | Version |
|---------|-------------|---------|
| [`dartvex`](packages/dartvex/) | Core client — WebSocket sync, subscriptions, auth | 0.1.4 |
| [`dartvex_flutter`](packages/dartvex_flutter/) | Flutter widgets — Provider, Query, Mutation | 0.1.4 |
| [`dartvex_codegen`](packages/dartvex_codegen/) | CLI code generator — type-safe Dart bindings from schema | 0.1.3 |
| [`dartvex_local`](packages/dartvex_local/) | Offline support — SQLite cache, mutation queue | 0.1.2 |
| [`dartvex_auth_better`](packages/dartvex_auth_better/) | Better Auth adapter | 0.1.3 |

## Architecture

```text
┌─────────────────────────────────────────────────┐
│                    Your App                     │
├───────────────┬──────────────┬──────────────────┤
│ dartvex_      │ dartvex_     │ dartvex_auth_*   │
│ flutter       │ local        │ (better)         │
│ (widgets)     │ (offline)    │ (auth adapters)  │
├───────────────┴──────────────┴──────────────────┤
│                    dartvex                      │
│         (core client + WebSocket sync)          │
├─────────────────────────────────────────────────┤
│                Convex Backend                   │
└─────────────────────────────────────────────────┘

                dartvex_codegen
     (generates typed bindings from schema)
```

## Installation

### 1. Add dependencies

```yaml
# pubspec.yaml
dependencies:
  dartvex: ^0.1.4
  dartvex_flutter: ^0.1.4  # If using Flutter

dev_dependencies:
  dartvex_codegen: ^0.1.3  # For code generation
```

### 2. Configure your client

```dart
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';

final client = ConvexClient('https://your-deployment.convex.cloud');
final runtime = ConvexClientRuntime(client);

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ConvexProvider(
      client: runtime,
      child: MaterialApp(home: HomePage()),
    );
  }
}
```

### 3. Generate type-safe bindings

```bash
dart run dartvex_codegen generate \
  --spec-file path/to/function_spec.json \
  --output lib/convex_api/
```

### 4. Use in your widgets

```dart
ConvexQuery<List<Message>>(
  query: 'messages:list',
  args: const {},
  decode: (v) => (v as List).map(Message.fromJson).toList(),
  builder: (context, snapshot) {
    if (snapshot.isLoading) return const CircularProgressIndicator();
    if (snapshot.hasError) return Text('Error: ${snapshot.error}');
    final messages = snapshot.data ?? const <Message>[];
    return ListView(children: messages.map(MessageTile.new).toList());
  },
)
```

## Usage Examples

### Queries

```dart
final sub = client.subscribe('tasks:list', {'projectId': 'abc123'});
sub.stream.listen((result) {
  if (result case QuerySuccess(:final value)) {
    print('Tasks: $value');
  }
});
```

### Mutations

```dart
await client.mutate('tasks:create', {
  'title': 'Ship dartvex',
  'projectId': 'abc123',
});
```

### Actions

```dart
final result = await client.action('ai:summarize', {
  'documentId': 'doc456',
});
```

### Authentication

```dart
final authClient = BetterAuthClient(
  baseUrl: 'https://your-deployment.convex.cloud',
);
final provider = ConvexBetterAuthProvider(client: authClient)
  ..email = 'user@example.com'
  ..password = 'securePassword';

final client = ConvexClient('https://your-deployment.convex.cloud');
final authedClient = client.withAuth(provider);
await authedClient.login();
```

### Offline Support

```dart
import 'package:dartvex_local/dartvex_local.dart';

final remoteClient = ConvexClient('https://your-deployment.convex.cloud');
final store = await SqliteLocalStore.open('my_app.sqlite');
final localClient = await ConvexLocalClient.open(
  client: remoteClient,
  config: LocalClientConfig(
    cacheStorage: store,
    queueStorage: store,
    disposeRemoteClient: true,
  ),
);

// Queries served from cache when offline
// Mutations queued and synced when back online
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.
