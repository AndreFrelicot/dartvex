import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';

void main() {
  Widget buildTestWidget({
    required FakeRuntimeClient client,
    required String query,
    required Map<String, dynamic> args,
    required void Function(ConvexQuerySnapshot<String> snapshot) onSnapshot,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ConvexProvider(
        client: client,
        child: ConvexQuery<String>(
          query: query,
          args: args,
          builder: (context, snapshot) {
            onSnapshot(snapshot);
            return Text(snapshot.hasData ? snapshot.data! : 'empty');
          },
        ),
      ),
    );
  }

  testWidgets('ConvexQuery starts in loading state and subscribes once', (
    tester,
  ) async {
    final client = FakeRuntimeClient();
    late ConvexQuerySnapshot<String> snapshot;

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: const <String, dynamic>{'channel': 'general'},
        onSnapshot: (value) => snapshot = value,
      ),
    );

    expect(snapshot.isLoading, isTrue);
    expect(snapshot.hasData, isFalse);
    expect(client.subscribeCalls, hasLength(1));
    expect(client.subscribeCalls.single.name, 'messages:list');
    expect(client.subscribeCalls.single.args, const <String, dynamic>{
      'channel': 'general',
    });
  });

  testWidgets('ConvexQuery delivers success events with snapshot metadata', (
    tester,
  ) async {
    final client = FakeRuntimeClient();
    late ConvexQuerySnapshot<String> snapshot;

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: const <String, dynamic>{},
        onSnapshot: (value) => snapshot = value,
      ),
    );

    client.subscribeCalls.single.subscription.emitSuccess(
      'hello',
      source: ConvexQuerySource.cache,
      hasPendingWrites: true,
    );
    await tester.pump();

    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasData, isTrue);
    expect(snapshot.data, 'hello');
    expect(snapshot.source, ConvexQuerySource.cache);
    expect(snapshot.hasPendingWrites, isTrue);
  });

  testWidgets('ConvexQuery delivers error events', (tester) async {
    final client = FakeRuntimeClient();
    late ConvexQuerySnapshot<String> snapshot;

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: const <String, dynamic>{},
        onSnapshot: (value) => snapshot = value,
      ),
    );

    client.subscribeCalls.single.subscription.emitError(StateError('boom'));
    await tester.pump();

    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasError, isTrue);
    expect(snapshot.error, isA<StateError>());
  });

  testWidgets('ConvexQuery resubscribes when args change', (tester) async {
    final client = FakeRuntimeClient();
    late ConvexQuerySnapshot<String> snapshot;

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: const <String, dynamic>{'channel': 'general'},
        onSnapshot: (value) => snapshot = value,
      ),
    );
    client.subscribeCalls.single.subscription.emitSuccess('first');
    await tester.pump();

    final firstSubscription = client.subscribeCalls.single.subscription;

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: const <String, dynamic>{'channel': 'random'},
        onSnapshot: (value) => snapshot = value,
      ),
    );

    expect(firstSubscription.isCanceled, isTrue);
    expect(client.subscribeCalls, hasLength(2));
    expect(snapshot.isRefreshing, isTrue);
    expect(snapshot.data, 'first');
  });

  testWidgets(
    'ConvexQuery does not resubscribe on rebuild with equivalent inputs',
    (tester) async {
      final client = FakeRuntimeClient();
      late ConvexQuerySnapshot<String> snapshot;

      await tester.pumpWidget(
        buildTestWidget(
          client: client,
          query: 'messages:list',
          args: const <String, dynamic>{'channel': 'general'},
          onSnapshot: (value) => snapshot = value,
        ),
      );
      await tester.pumpWidget(
        buildTestWidget(
          client: client,
          query: 'messages:list',
          args: const <String, dynamic>{'channel': 'general'},
          onSnapshot: (value) => snapshot = value,
        ),
      );

      expect(snapshot.isLoading, isTrue);
      expect(client.subscribeCalls, hasLength(1));
    },
  );

  testWidgets('ConvexQuery unsubscribes on dispose', (tester) async {
    final client = FakeRuntimeClient();

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: const <String, dynamic>{},
        onSnapshot: (_) {},
      ),
    );

    final subscription = client.subscribeCalls.single.subscription;
    await tester.pumpWidget(const SizedBox());

    expect(subscription.isCanceled, isTrue);
  });
}
