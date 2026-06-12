import 'dart:async';

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

  testWidgets('ConvexQuery renders loading events from optimistic clear', (
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

    client.subscribeCalls.single.subscription.emitSuccess('hello');
    await tester.pump();
    expect(snapshot.hasData, isTrue);
    expect(snapshot.isLoading, isFalse);

    client.subscribeCalls.single.subscription.emitLoading(
      hasPendingWrites: true,
    );
    await tester.pump();

    expect(snapshot.isLoading, isTrue);
    expect(snapshot.hasData, isFalse);
    expect(snapshot.data, isNull);
    expect(snapshot.hasPendingWrites, isTrue);
    expect(find.text('empty'), findsOneWidget);
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

  testWidgets('ConvexQuery maps raw stream errors to the snapshot', (
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

    client.subscribeCalls.single.subscription.emitStreamError(
      StateError('stream failed'),
    );
    await tester.pump();

    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasError, isTrue);
    expect(snapshot.error, isA<StateError>());
    expect(tester.takeException(), isNull);
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

  testWidgets('ConvexQuery resubscribes when the args map is mutated in place',
      (tester) async {
    final client = FakeRuntimeClient();
    final args = <String, dynamic>{'channel': 'general'};

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: args,
        onSnapshot: (_) {},
      ),
    );

    final firstSubscription = client.subscribeCalls.single.subscription;
    args['channel'] = 'random';

    await tester.pumpWidget(
      buildTestWidget(
        client: client,
        query: 'messages:list',
        args: args,
        onSnapshot: (_) {},
      ),
    );

    expect(firstSubscription.isCanceled, isTrue);
    expect(client.subscribeCalls, hasLength(2));
    expect(client.subscribeCalls.last.args, const <String, dynamic>{
      'channel': 'random',
    });
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

  testWidgets('ConvexQuery ignores stale events from canceled subscriptions', (
    tester,
  ) async {
    final client = _StaleEventRuntimeClient();
    addTearDown(() async {
      for (final subscription in client.subscriptions) {
        await subscription.close();
      }
    });
    late ConvexQuerySnapshot<String> snapshot;

    Widget build(String channel) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: ConvexProvider(
          client: client,
          child: ConvexQuery<String>(
            query: 'messages:list',
            args: <String, dynamic>{'channel': channel},
            builder: (context, value) {
              snapshot = value;
              return Text(value.data ?? 'empty');
            },
          ),
        ),
      );
    }

    await tester.pumpWidget(build('general'));
    final firstSubscription = client.subscriptions.single;

    await tester.pumpWidget(build('random'));
    final secondSubscription = client.subscriptions.last;
    secondSubscription.emitSuccess('fresh');
    await tester.pump();
    expect(snapshot.data, 'fresh');

    expect(firstSubscription.isCanceled, isTrue);
    firstSubscription.emitSuccess('stale');
    await tester.pump();

    expect(snapshot.data, 'fresh');
  });
}

class _StaleEventRuntimeClient extends FakeRuntimeClient {
  final List<_StaleEventSubscription> subscriptions =
      <_StaleEventSubscription>[];

  @override
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final subscription = _StaleEventSubscription();
    subscriptions.add(subscription);
    return subscription;
  }
}

class _StaleEventSubscription implements ConvexRuntimeSubscription {
  final StreamController<ConvexRuntimeQueryEvent> _controller =
      StreamController<ConvexRuntimeQueryEvent>.broadcast(sync: true);
  bool isCanceled = false;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _controller.stream;

  void emitSuccess(String value) {
    _controller.add(ConvexRuntimeQuerySuccess(value));
  }

  @override
  void cancel() {
    isCanceled = true;
  }

  Future<void> close() => _controller.close();
}
