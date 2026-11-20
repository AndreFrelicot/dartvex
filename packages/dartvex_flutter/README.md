<p align="center">
  <a href="https://github.com/AndreFrelicot/dartvex">
    <img src="https://raw.githubusercontent.com/AndreFrelicot/dartvex/main/assets/dartvex-logo-512.png" width="128" alt="Dartvex" />
  </a>
</p>

# dartvex_flutter

Flutter widgets and builders for [dartvex](https://pub.dev/packages/dartvex) — the pure Dart client for [Convex](https://convex.dev).

`dartvex_flutter` removes the repetitive widget lifecycle code around realtime
Convex subscriptions, mutations, actions, and connection state. The widgets
talk to a small runtime interface (`ConvexRuntimeClient`), so other clients —
a test fake, or an adapter over an offline client — can drive the same
widgets. Custom implementations of that interface may need updates when a
release adds members to it (0.2.0 did; see the CHANGELOG).

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
| [`dartvex_codegen`](https://pub.dev/packages/dartvex_codegen) | CLI code generator — type-safe Dart bindings from function validators |
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
- `FakeConvexAuthClient` — test helper for auth flows
- `watch` — decoded `Stream<T>` of a live query, for code outside widgets
- App lifecycle reconnect when a Flutter app resumes while disconnected
- NSURLSession network transports on iOS and macOS, installed automatically
- Runtime-interface based — works with `ConvexClientRuntime` or any custom
  `ConvexRuntimeClient`. No adapter for `dartvex_local`'s `ConvexLocalClient`
  ships yet; the example app contains a sample one
  (`example/flutter_app/lib/src/core/local_runtime_client.dart`, without
  pagination support) that you can copy.

The core storage flow works on web: resolve a signed storage URL and render it
with `Image.network`. The `ConvexImage`, `ConvexCachedImage`,
`ConvexOfflineImage`, and `ConvexAssetCache` helpers are native-only because
they use `dart:io` and `flutter_cache_manager` for streaming downloads and disk
cache/offline fallback. On web (JS and WASM) builds the package exports
API-compatible stand-ins instead, so shared code still compiles: the widgets
render their `errorBuilder` / `errorWidget` with an `UnsupportedError`, and
`ConvexAssetCache` / `ConvexFileDownloader` calls fail with an
`UnsupportedError`.

## Installation

```yaml
dependencies:
  dartvex: ^0.3.0
  dartvex_flutter: ^0.3.0
```

Requires Dart `^3.10.0` and Flutter `>=3.38.1`. On Apple platforms the
NSURLSession transport (`cupertino_http` 3) requires iOS 15 or later and
macOS 12 or later; set `IPHONEOS_DEPLOYMENT_TARGET` / `MACOSX_DEPLOYMENT_TARGET`
(and the `platform` line of your Podfile, if any) accordingly.

## Platform Transports

On iOS and macOS the plugin automatically installs NSURLSession-backed
transports at startup (via Dart plugin registration, before `main()` runs).
Every network path the SDK uses — the sync WebSocket, storage uploads, auth
endpoints, asset-cache downloads, and `ConvexFileDownloader` — then travels
the same system network stack as Safari and native apps instead of raw
`dart:io` sockets. POSIX sockets bypass VPNs, proxies, and per-app network
policy, and are blackholed with `errno 65` on some iOS devices, which is why
Apple discourages them.

Android, Linux, and Windows keep the default `dart:io` transport; web uses
`package:web`. To opt back into `dart:io` on Apple platforms, reset the
process-wide seams:

```dart
import 'package:dartvex_flutter/dartvex_flutter.dart';

void main() {
  defaultWebSocketAdapterOverride = null;
  defaultHttpClientFactory = null;
  runApp(const MyApp());
}
```

A per-client `ConvexClientConfig.adapterFactory` or an explicitly provided
HTTP client always takes precedence over the installed defaults.

The installed transports use an ephemeral, cookie-less NSURLSession
configuration, like the `dart:io` and web transports: no cookie is stored or
sent, so a session cookie returned by an auth endpoint (for example a Better
Auth sign-in) never rides along on later bearer-authenticated requests. All
sync WebSocket connections share one URLSession, so reconnects do not create
new native sessions.

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

Create the client and its `ConvexClientRuntime` once (not inside `build`).
Code below the provider can build generated `ConvexApi` bindings
(`dartvex_codegen`) or a `ConvexStorage` from the provider's client with
`ConvexProvider.of(context).functionCaller`; `FakeConvexClient` supports the
same call in widget tests.

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
  decode: decodeMessages, // a stable reference avoids re-decoding on rebuilds
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

`ConvexMutation` and `ConvexAction` are single-flight: while a call is in
flight (`snapshot.isLoading`), a second call is not sent and its future
rejects with a `StateError`. A mutation stays in flight until the server
confirms it, including while the client is offline. Disable the trigger while
loading, as below, or call `ConvexProvider.of(context).mutate(...)` directly
when several mutations must be queued at once.

```dart
// T is the mutation's return type: here `messages:send` returns the new
// document ID. Use ConvexMutation<void> for a mutation that returns nothing.
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

A result that cannot be decoded into `T` (or by `decode:`) fails the call
with a `ConvexDecodeException`, even though the write was committed.

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
  errorBuilder: (context, error, retry) =>
      IconButton(icon: const Icon(Icons.refresh), onPressed: retry),
)
```

`ConvexImage` and `ConvexCachedImage` resolve storage URLs with a Convex query
by default. Set `useAction: true` when the resolver is implemented as an action.
On failure, `errorBuilder` receives the error and a `retry` callback; without
`errorBuilder` or `errorWidget` the error is reported to
`FlutterError.reportError`. `ConvexAssetCache()` instances with the same
`cacheKey` share one store (`ConvexAssetCache.shared` uses the default key).
Cached files are keyed by the bare `storageId`, not by deployment: an app that
shows files from several deployments should pass each one its own cache, e.g.
`cache: ConvexAssetCache(cacheKey: 'deploymentA')`. A forced refresh
(`prefetch(..., force: true)`, or a mounted `ConvexCachedImage` whose client
or URL resolver changed) replaces the cached file only once the new download
has fully arrived. Errors never include the signed URL beyond its origin.
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
  // Optional: receives the error object (server error or a
  // ConvexDecodeException) and a retry callback.
  errorBuilder: (context, error, items, retry) =>
      TextButton(onPressed: retry, child: Text('Failed: $error')),
)
```

`loadMore` can also be called from an `itemBuilder` (infinite scroll); the
rebuild it triggers is deferred to after the current frame.

## Testing

```dart
final client = FakeConvexClient()
  ..whenQuery('messages:list', returns: [mockMessage1, mockMessage2])
  // Stub a value that fits the widget's type (ConvexMutation<String> above).
  ..whenMutation('messages:send', returns: 'msg_1');

await tester.pumpWidget(
  ConvexProvider(client: client, child: MyApp()),
);

client.emitSubscription('messages:list', updatedMessages); // server push
await tester.pump();
expect(client.mutationCalls, isEmpty);
```

`emitSubscription`, `emitSubscriptionError`, `emitSubscriptionLoading` and
`emitPaginated` reach every live subscription with that name unless you pass
`args:`. Calls are recorded in `queryCalls`, `mutationCalls` and
`actionCalls`; optimistic updates are recorded but not applied. The
`FakeConvexClient` dartdoc lists the other differences from the real
client.

`FakeConvexAuthClient<T>` replaces `ConvexClientWithAuth<T>` in auth tests:

```dart
final auth = FakeConvexAuthClient<Session>(client: client)
  ..onLoginFromCache = () => session; // return a user or throw

await tester.pumpWidget(
  ConvexProvider(
    client: client,
    child: ConvexAuthProvider<Session>(client: auth, child: MyApp()),
  ),
);
await auth.loginFromCache(); // AuthLoading, then AuthAuthenticated
await tester.pump();
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
      // Single-flight: disable while the mutation is in flight (or offline
      // and waiting for the reconnect), otherwise a second tap is dropped.
      onPressed: snapshot.isLoading
          ? null
          : () => mutate({'channel': 'general', 'text': 'Hello'}),
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
    if (!status.isWebSocketConnected) {
      return Text(status.hasEverConnected
          ? 'Reconnecting (attempt ${status.connectionRetries})'
          : 'Connecting…');
    }
    if (status.isLoading) return const Text('Syncing…');
    return Text('Online — ${status.inflightMutations} pending');
  },
)
```

`isLoading` means "catching up after a reconnect"; it stays `false` while the
socket is down, so use `isWebSocketConnected` (or `isConnected`, which also
requires the re-sync to finish) for offline indicators.

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
| `FakeConvexAuthClient` | Test double for `ConvexClientWithAuth` |

## Full Documentation

See the [Dartvex monorepo](https://github.com/AndreFrelicot/dartvex) for full documentation and examples.
