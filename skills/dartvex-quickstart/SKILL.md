---
name: dartvex-quickstart
description: Connect a Dart or Flutter app to a Convex backend with the dartvex SDK - add dependencies, create the client, run the first query, mutation, and live subscription. Use when starting a new dartvex integration, when the user says "use Convex from Flutter/Dart", or when wiring an existing app to a Convex deployment.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Dartvex Quickstart

Goal: a Dart or Flutter app talking to a Convex deployment — one query, one
mutation, one live subscription.

If you are unfamiliar with how a Convex deployment is consumed (function
paths, query/mutation/action semantics, type mapping), read
[references/convex-interface.md](references/convex-interface.md) first.

## Step 1 — Add dependencies

Flutter app (pulls in `dartvex` automatically):

```yaml
dependencies:
  dartvex: ^0.2.0
  dartvex_flutter: ^0.2.0
```

Pure Dart (CLI, server):

```yaml
dependencies:
  dartvex: ^0.2.0
```

`dartvex_flutter` requires Dart `^3.8.0` and Flutter `>=3.32.0`.

## Step 2 — Get a deployment URL (never commit it)

The client needs the deployment URL (`https://<name>.convex.cloud`), shown by
`npx convex dashboard` or in `.env.local` of the Convex project. Pass it at
run time — never hardcode a real URL in committed code:

```bash
flutter run --dart-define=CONVEX_URL=https://your-deployment.convex.cloud
```

```dart
const deploymentUrl = String.fromEnvironment('CONVEX_URL');
```

If there is no backend yet, a minimal one is enough to verify the wiring
(anything more belongs to the official Convex skills —
`npx skills add get-convex/agent-skills`):

```typescript
// convex/messages.ts
import { query, mutation } from "./_generated/server";
import { v } from "convex/values";

export const list = query({
  args: { channel: v.string() },
  handler: (ctx, args) =>
    ctx.db
      .query("messages")
      .filter((q) => q.eq(q.field("channel"), args.channel))
      .collect(),
});

export const send = mutation({
  args: { channel: v.string(), body: v.string() },
  handler: async (ctx, args) => {
    await ctx.db.insert("messages", args);
  },
});
```

## Step 3 — Create the client

```dart
import 'package:dartvex/dartvex.dart';

final client = ConvexClient(deploymentUrl);
```

The WebSocket opens on construction and reconnects automatically with
jittered exponential backoff. Pass
`config: const ConvexClientConfig(connectImmediately: false)` to defer the
connection until first use.

## Step 4 — Query, mutate, subscribe

```dart
// One-shot read (throws ConvexException on failure):
final messages = await client.query('messages:list', {'channel': 'general'});

// Typed one-shot read for non-reactive screens:
final name = await client.queryOnce<String>('users:getName', {'id': userId});

// Write:
await client.mutate('messages:send', {'channel': 'general', 'body': 'Hello'});

// Live subscription — re-emits on every server change:
final subscription = client.subscribe('messages:list', {'channel': 'general'});
subscription.stream.listen((result) {
  switch (result) {
    case QuerySuccess(:final value):
      print(value);
    case QueryError(:final message):
      print('query failed: $message');
    case QueryLoading():
      break; // transient; a concrete result follows
  }
});
// Later: subscription.cancel();
```

## Step 5 (Flutter) — Provider and first reactive widget

```dart
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';

void main() {
  final client = ConvexClient(deploymentUrl);
  runApp(ConvexProvider(
    client: ConvexClientRuntime(client),
    child: const MyApp(),
  ));
}
```

```dart
ConvexQuery<List<dynamic>>(
  query: 'messages:list',
  args: const {'channel': 'general'},
  decode: (value) => value as List<dynamic>,
  builder: (context, snapshot) {
    if (snapshot.isLoading) return const CircularProgressIndicator();
    if (snapshot.hasError) return Text(snapshot.error.toString());
    final messages = snapshot.data ?? const [];
    return ListView(
      children: [for (final m in messages) Text('${m['body']}')],
    );
  },
)
```

On iOS/macOS, `dartvex_flutter` automatically installs NSURLSession-backed
transports (same network path as Safari); no setup needed.

## Verify

1. `flutter run` (or `dart run`) with the `--dart-define` URL.
2. Trigger the mutation; the subscription/widget updates without a refresh.
3. Kill the network briefly; the client reconnects and the data re-syncs.

## Common mistakes

- **Hardcoding the deployment URL** — always inject it at run time.
- Using `BigInt` for `v.number()` args — plain `int`/`double` map to
  `v.number()`; `convexInt64()`/`BigInt` are only for `v.int64()`.
- Treating `QueryLoading` as an error — it is a transient state (e.g. an
  optimistic clear); a concrete result always follows.
- Forgetting `subscription.cancel()` for hand-managed subscriptions
  (Flutter widgets from `dartvex_flutter` manage this automatically).

## Next steps

- Type-safe API instead of raw strings/maps: `dartvex-generate-bindings`
- Auth: `dartvex-setup-auth`
- Reactive lists, pagination, optimistic UI: `dartvex-build-realtime-ui`
- Offline: `dartvex-setup-offline`
