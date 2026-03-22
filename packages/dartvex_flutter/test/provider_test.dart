import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';
import 'test_helpers/lifecycle_test_helpers.dart';

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
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.disconnected,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: const SizedBox(),
          ),
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
    'ConvexProvider does not call reconnectNow on resume when connected',
    (tester) async {
      final client = FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: const SizedBox(),
          ),
        ),
      );

      simulateAppLifecycleState(tester, AppLifecycleState.paused);
      await tester.pump();
      simulateAppLifecycleState(tester, AppLifecycleState.resumed);
      await tester.pump();

      expect(client.reconnectNowCalls, isEmpty);
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
