---
name: dartvex-test-with-fakes
description: Test Flutter widgets and app logic that use dartvex without a live Convex backend - FakeConvexClient stubs for queries, mutations, and subscription pushes in widget tests. Use when writing or fixing tests for dartvex-based screens, or when tests should not hit a real deployment.
license: MIT
metadata:
  author: AndreFrelicot
  ecosystem-version: "0.2.0"
---

# Test Dartvex Apps with FakeConvexClient

`FakeConvexClient` (from `dartvex_flutter`) implements the same runtime
interface as the real client, so every dartvex widget works against it —
no network, no deployment.

## Setup

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
```

(`FakeConvexClient` ships in `dartvex_flutter` itself — no extra package.)

## Widget test pattern

```dart
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders messages from Convex', (tester) async {
    final client = FakeConvexClient()
      ..whenQuery('messages:list', returns: [
        {'_id': '1', 'body': 'Hello'},
        {'_id': '2', 'body': 'World'},
      ])
      ..whenMutation('messages:send', returns: {'id': 'xxx'});

    await tester.pumpWidget(
      ConvexProvider(client: client, child: const MyApp()),
    );
    await tester.pump();

    expect(find.text('Hello'), findsOneWidget);
  });
}
```

The same `ConvexProvider` used in production takes the fake directly —
widgets under test are unchanged.

## Stubbing surface

```dart
final client = FakeConvexClient()
  // Fixed results:
  ..whenQuery('messages:list', returns: [...])
  ..whenMutation('messages:send', returns: {'id': 'xxx'})
  ..whenAction('emails:send', returns: null)
  // Args-dependent results:
  ..whenQueryWith('messages:list', (args) => byChannel[args['channel']]);
```

Drive live behavior mid-test (then `await tester.pump()`):

```dart
client.emitSubscription('messages:list', updatedMessages); // server push
client.emitSubscriptionError('messages:list', ConvexException('boom'));
client.emitPaginated('messages:paginate', results: items, isDone: false);
client.emitConnectionState(ConvexConnectionState.disconnected);
client.emitConnectionStatus(richStatus);   // ConvexConnectionStatusBuilder
client.emitAuthRefreshing(true);           // ConvexAuthRefreshingBuilder
```

## What to cover

- **Loading state**: before any result is stubbed/pushed, `ConvexQuery`
  renders its loading branch — assert the spinner.
- **Error state**: `emitSubscriptionError` to assert the error branch.
- **Mutations**: `whenMutation` + tap the button; assert the success path
  and the `isLoading` button-disable behavior.
- **Live updates**: `emitSubscription` with a new value and `pump()` — the
  widget must re-render (this is the core value of dartvex; test it).
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
