---
name: dartvex-build-realtime-ui
description: Build reactive Flutter UI on Convex with dartvex_flutter - live query widgets, mutations with optimistic updates, gapless pagination, connection and auth-state banners. Use when building lists/feeds/chat that update in real time, infinite scroll, offline indicators, or any Flutter widget driven by Convex data.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Build Realtime Flutter UI

Prerequisite: a `ConvexProvider` at the root of the tree
(see `dartvex-quickstart`):

```dart
ConvexProvider(client: ConvexClientRuntime(client), child: const MyApp())
```

All widgets below find the client via the provider; pass `client:` explicitly
only to override.

## Live data — ConvexQuery

```dart
ConvexQuery<List<Message>>(
  query: 'messages:list',
  args: const {'channel': 'general'},
  decode: (value) => [
    for (final m in value as List) Message.fromJson(m as Map<String, dynamic>),
  ],
  builder: (context, snapshot) {
    if (snapshot.isLoading) return const CircularProgressIndicator();
    if (snapshot.hasError) return Text(snapshot.error.toString());
    final messages = snapshot.data ?? const <Message>[];
    return ListView(
      children: [for (final m in messages) MessageTile(m)],
    );
  },
)
```

- Subscribes on mount, cancels on dispose, re-renders on every server push.
- The subscription identity is `client + query + args` (deep-compared):
  changing them resubscribes; an inline `decode` closure does NOT — but a
  *changed* decoder re-decodes the latest data.

## Writes — ConvexMutation / ConvexAction

```dart
ConvexMutation<String>(
  mutation: 'messages:send',
  builder: (context, mutate, snapshot) {
    return FilledButton(
      onPressed: snapshot.isLoading
          ? null
          : () => mutate({'channel': 'general', 'body': 'Hello'}),
      child: Text(snapshot.isLoading ? 'Sending…' : 'Send'),
    );
  },
)
```

`ConvexAction` is identical for Convex actions.

### Optimistic updates

Overlay query results the instant the mutation is sent; automatic rollback
when it settles or fails:

```dart
ConvexMutation<String>(
  mutation: 'messages:send',
  optimisticUpdate: (store) {
    final existing =
        store.getQuery('messages:list', const {'channel': 'general'});
    final messages =
        existing is List ? List<dynamic>.from(existing) : <dynamic>[];
    messages.add({'_id': 'optimistic', 'body': 'Hello'});
    store.setQuery('messages:list', const {'channel': 'general'}, messages);
  },
  builder: (context, mutate, snapshot) => /* … */,
)
```

Rules: the update must be **pure** (it is replayed on every fresh server
result while pending). `store.setQuery(..., null)` sets a real Convex
`null`; use `store.clearQuery(name, args)` to reset to loading.

## Infinite scroll — PaginatedQueryBuilder

For Convex paginated queries (functions taking `paginationOpts`). Loaded
pages stay live and gapless; do not build `paginationOpts` yourself:

```dart
PaginatedQueryBuilder<Message>(
  query: 'messages:paginate',
  args: const {'channel': 'general'},
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

Identity caveat: changing `query`, `args`, `pageSize`, or `client` resets the
loaded pages (a changed `fromJson` alone does not — pages are kept and
re-mapped).

## Connection and auth indicators

```dart
// Rich status: syncing, retries, inflight writes
ConvexConnectionStatusBuilder(
  builder: (context, status) {
    if (status.isLoading) return const Text('Syncing…');
    if (!status.isWebSocketConnected) {
      return Text('Reconnecting (attempt ${status.connectionRetries})');
    }
    return Text('Online — ${status.inflightMutations} pending');
  },
)

// Auth recovery (token being refreshed after a server rejection)
ConvexAuthRefreshingBuilder(
  builder: (context, isRefreshing) =>
      isRefreshing ? const LinearProgressIndicator() : const SizedBox.shrink(),
)
```

Coarse variants: `ConvexConnectionBuilder`, `ConvexConnectionIndicator`.
`status.isConnected` means socket up AND fully re-synced — prefer it over
raw socket state for "online" badges.

To reconnect instantly when connectivity returns (instead of waiting out
backoff), construct the client with
`ConvexClientConfig(connectivitySignal: ConnectivityPlusSignal())`.

## Common mistakes

- Rebuilding `args` as a new non-const map with the same contents is fine
  (deep-compared), but *changing* contents resets pagination — hoist filter
  state deliberately.
- Doing writes in `decode`/`builder` — keep them pure; side effects belong
  in `mutate` callbacks.
- Showing "offline" from `isWebSocketConnected` alone — use `isConnected`
  (sync-aware) or `status.isLoading`.
- For generic layout/navigation/styling work, use the official Flutter
  skills: `npx skills add flutter/skills`.
