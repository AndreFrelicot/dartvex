---
name: dartvex-test-with-fakes
description: Test Flutter widgets and app logic that use dartvex without a live Convex backend - FakeConvexClient stubs for queries, mutations, and subscription pushes in widget tests. Use when writing or fixing tests for dartvex-based screens, or when tests should not hit a real deployment.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.3.0"
---

# Test Dartvex Apps with FakeConvexClient

`FakeConvexClient` (from `dartvex_flutter`) implements the same runtime
interface as the real client, so every dartvex widget works against it —
no network, no deployment.

## Setup

```yaml
dependencies:
  dartvex: ^0.3.0          # for ConvexException in error stubs
  dartvex_flutter: ^0.3.0  # FakeConvexClient ships here

dev_dependencies:
  flutter_test:
    sdk: flutter
```

## Widget test pattern

```dart
import 'package:dartvex/dartvex.dart' show ConvexException;
import 'package:dartvex_flutter/dartvex_flutter.dart';
// dartvex_flutter also re-exports AuthState and its subclasses.
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders messages from Convex', (tester) async {
    final client = FakeConvexClient()
      ..whenQuery('messages:list', returns: [
        {'_id': '1', 'body': 'Hello'},
        {'_id': '2', 'body': 'World'},
      ])
      // The stub's value must fit the widget's type: ConvexMutation<String>
      // for a mutation returning an ID.
      ..whenMutation('messages:send', returns: 'msg_1');

    await tester.pumpWidget(
      ConvexProvider(client: client, child: const MyApp()),
    );
    await tester.pump();

    expect(find.text('Hello'), findsOneWidget);
  });
}
```

The same `ConvexProvider` used in production takes the fake directly —
widgets under test are unchanged. Generated bindings work too:
`ConvexApi(ConvexProvider.of(context).functionCaller)` is served by the same
stubs (the fake's typed `paginatedQuery` is unsupported).

## Stubbing surface

```dart
final client = FakeConvexClient()
  // Fixed results:
  ..whenQuery('messages:list', returns: [...])
  ..whenMutation('messages:send', returns: 'msg_1')
  ..whenAction('emails:send', returns: null)
  // Args-dependent results (throw from the handler to simulate a failure):
  ..whenQueryWith('messages:list', (args) => byChannel[args['channel']]);

// Every call is recorded:
expect(client.mutationCalls.single.args, {'channel': 'general', 'body': 'Hi'});
```

Drive live behavior mid-test (then `await tester.pump()`):

```dart
client.emitSubscription('messages:list', updatedMessages); // server push
client.emitSubscriptionError('messages:list', const ConvexException('boom'));
client.emitSubscriptionLoading('messages:list');           // optimistic clear
client.emitPaginated('messages:paginate', results: items, isDone: false);
// Emissions reach every live subscription with that name; when the same
// query is mounted with different args, target one with `args:`:
client.emitSubscription('messages:list', general,
    args: const {'channel': 'general'});
client.emitConnectionState(ConvexConnectionState.disconnected);
client.emitConnectionStatus(richStatus);   // ConvexConnectionStatusBuilder
client.emitAuthRefreshing(true);           // ConvexAuthRefreshingBuilder
```

## Auth flows — FakeConvexAuthClient

`FakeConvexAuthClient<T>` stands in for `ConvexClientWithAuth<T>` (any
`ConvexAuthClient<T>`): script each auth call, push states, count calls.
Function calls and the connection state go to its `FakeConvexClient`.

```dart
final convex = FakeConvexClient()..whenQuery('users:me', returns: me);
final auth = FakeConvexAuthClient<Session>(client: convex)
  ..onLoginFromCache = () => session          // or throw to fail
  ..onLogin = () => throw StateError('wrong password');

await tester.pumpWidget(
  ConvexProvider(
    client: convex,
    child: ConvexAuthProvider<Session>(client: auth, child: const MyApp()),
  ),
);

await auth.loginFromCache();       // AuthLoading, then AuthAuthenticated
await tester.pump();
expect(auth.loginFromCacheCalls, 1);
auth.emit(const AuthUnauthenticated<Session>()); // e.g. session revoked
```

It follows the real wrapper's rules: a failing `login`/`loginFromCache`
keeps a previous `AuthAuthenticated` state unless the error implements
`AuthSessionEndedError`; without `onLoginFromCache` it fails like a provider
with no stored session; `logout()` and `clearAuth()` end signed out.

To test code that consumes `watch(...)` streams, use the fake as is:
`FakeConvexClient().watch(...)` emits what `emitSubscription` pushes. Push
`source: ConvexQuerySource.cache` (without `hasPendingWrites`) to simulate
the cached seed that `skipCached: true` drops.

## What to cover

- **Loading state**: before any result is stubbed/pushed, `ConvexQuery`
  renders its loading branch — assert the spinner.
- **Error state**: `emitSubscriptionError` to assert the error branch.
- **Mutations**: `whenMutation` + tap the button; assert the success path.
  A `whenMutation` stub resolves before the next frame, so to see the
  in-flight (`isLoading`, button disabled) state, hold the mutation open:

  ```dart
  final pending = Completer<String>(); // import 'dart:async';
  client.whenMutationWith('messages:send', (_) => pending.future);
  await tester.tap(find.text('Send'));
  await tester.pump();
  expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull);
  pending.complete('msg_1');
  await tester.pump();
  ```
- **Live updates**: `emitSubscription` with a new value and `pump()` — the
  widget must re-render (this is the core value of dartvex; test it).
- **Auth screens**: `FakeConvexAuthClient` for signed-out, loading,
  failed-login and session-ended branches.
- **Connection/auth banners**: `emitConnectionStatus` /
  `emitAuthRefreshing` drive the indicator widgets deterministically.

## Scope guidance

- Use `FakeConvexClient` for **widget/unit tests** of UI and app logic.
- Do not fake what you do not own beyond this seam — for end-to-end
  confidence against a real deployment, run a live integration suite
  separately (real URL injected via environment, never committed).
- Generic widget-testing technique (finders, pumpAndSettle, golden tests):
  official Flutter skills — `npx skills add flutter/skills`.

## Common mistakes

- Wrapping the fake in `ConvexClientRuntime` — the fake IS a runtime;
  pass it to `ConvexProvider` directly.
- Forgetting `await tester.pump()` after a pushed update — emissions are
  asynchronous.
- Asserting on real-client behaviors (reconnect/backoff) through the fake —
  those are core-SDK concerns, already covered by the SDK's own test suite.
  Optimistic updates passed to `mutate` are recorded
  (`mutationCalls.last.optimisticUpdate`) but not applied.
- Using the fake after `dispose()` — like the real client, every call then
  throws `ConvexException('ConvexClient has been disposed')`.
- Stubbing a value that does not fit the widget's type (a `Map` for a
  `ConvexMutation<String>`) — the widget reports a `ConvexDecodeException`.
