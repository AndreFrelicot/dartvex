import 'package:dartvex/dartvex.dart' show ConvexException;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';
import 'test_helpers/lifecycle_test_helpers.dart';

/// A runtime client that connected before and is now disconnected — as
/// opposed to a lazy client that has not started yet.
FakeRuntimeClient disconnectedAfterConnecting() {
  return FakeRuntimeClient()..emitConnectionStatus(
    const ConnectionStatus(
      state: ConvexConnectionState.disconnected,
      isWebSocketConnected: false,
      isConnected: false,
      hasEverConnected: true,
      connectionCount: 1,
      connectionRetries: 0,
      inflightMutations: 0,
      inflightActions: 0,
      timeOfOldestInflightRequest: null,
      hasSyncedPastLastReconnect: false,
    ),
  );
}

void main() {
  testWidgets('ConvexProvider resolves runtime client from context', (
    tester,
  ) async {
    final client = FakeRuntimeClient();
    late ConvexRuntimeClient resolved;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ConvexProvider(
          client: client,
          child: Builder(
            builder: (context) {
              resolved = ConvexProvider.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(identical(resolved, client), isTrue);
  });

  testWidgets('ConvexProvider.of throws clearly when missing', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            ConvexProvider.of(context);
            return const SizedBox();
          },
        ),
      ),
    );

    final exception = tester.takeException();
    expect(exception, isA<FlutterError>());
    expect(
      exception.toString(),
      contains('ConvexProvider.of() called with no ConvexProvider'),
    );
  });

  testWidgets(
    'ConvexProvider calls reconnectNow on app resume when disconnected',
    (tester) async {
      final client = disconnectedAfterConnecting();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(client: client, child: const SizedBox()),
        ),
      );

      simulateAppLifecycleState(tester, AppLifecycleState.paused);
      await tester.pump();
      simulateAppLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();

      expect(client.reconnectNowCalls, contains('AppResumed'));
    },
  );

  testWidgets(
    'ConvexProvider does not start a lazy client that has not started yet',
    (tester) async {
      // connectImmediately: false — disconnected, never connected, no retry.
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.disconnected,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(client: client, child: const SizedBox()),
        ),
      );

      simulateAppLifecycleState(tester, AppLifecycleState.inactive);
      await tester.pump();
      simulateAppLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();

      expect(client.reconnectNowCalls, isEmpty);
    },
  );

  testWidgets(
    'ConvexProvider does not call reconnectNow on resume when connected',
    (tester) async {
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(client: client, child: const SizedBox()),
        ),
      );

      simulateAppLifecycleState(tester, AppLifecycleState.paused);
      await tester.pump();
      simulateAppLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();

      expect(client.reconnectNowCalls, isEmpty);
    },
  );

  testWidgets(
    'ConvexProvider swallows the disposed-client error on app resume',
    (tester) async {
      // An externally owned client (disposeClient: false) can be disposed
      // while the app is backgrounded with the provider still mounted; the
      // disposed assertion must not escape into the lifecycle dispatch.
      final client = disconnectedAfterConnecting()
        ..reconnectNowSyncError = const ConvexException(
          'ConvexClient has been disposed',
        );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(client: client, child: const SizedBox()),
        ),
      );

      simulateAppLifecycleState(tester, AppLifecycleState.paused);
      await tester.pump();
      simulateAppLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(client.reconnectNowCalls, isEmpty);
    },
  );

  testWidgets(
    'ConvexProvider swallows an async disposed-client error on app resume',
    (tester) async {
      final client = disconnectedAfterConnecting()
        ..reconnectNowAsyncError = const ConvexException(
          'ConvexClient has been disposed',
        );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(client: client, child: const SizedBox()),
        ),
      );

      simulateAppLifecycleState(tester, AppLifecycleState.paused);
      await tester.pump();
      simulateAppLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(client.reconnectNowCalls, contains('AppResumed'));
    },
  );

  testWidgets('ConvexProvider disposes owned clients', (tester) async {
    final client = FakeRuntimeClient();

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ConvexProvider(
          client: client,
          disposeClient: true,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());

    expect(client.disposed, isTrue);
  });
}
