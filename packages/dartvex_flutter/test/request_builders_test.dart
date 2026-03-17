import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';

void main() {
  Widget wrapWithProvider({
    required FakeRuntimeClient client,
    required Widget child,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ConvexProvider(client: client, child: child),
    );
  }

  testWidgets('ConvexMutation exposes loading and success state', (
    tester,
  ) async {
    final client = FakeRuntimeClient();
    final completer = Completer<dynamic>();
    client.onMutate = (_, __) => completer.future;

    late ConvexRequestExecutor<String> mutate;
    late ConvexRequestSnapshot<String> snapshot;

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexMutation<String>(
          mutation: 'messages:send',
          builder: (context, execute, state) {
            mutate = execute;
            snapshot = state;
            return const SizedBox();
          },
        ),
      ),
    );

    final future = mutate(const <String, dynamic>{'text': 'hello'});
    await tester.pump();

    expect(snapshot.isLoading, isTrue);
    expect(client.mutateCalls.single.name, 'messages:send');
    expect(client.mutateCalls.single.args, const <String, dynamic>{
      'text': 'hello',
    });

    completer.complete('ok');
    expect(await future, 'ok');
    await tester.pump();

    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasData, isTrue);
    expect(snapshot.data, 'ok');
  });

  testWidgets('ConvexMutation exposes errors', (tester) async {
    final client = FakeRuntimeClient();
    final completer = Completer<dynamic>();
    client.onMutate = (_, __) => completer.future;

    late ConvexRequestExecutor<String> mutate;
    late ConvexRequestSnapshot<String> snapshot;

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexMutation<String>(
          mutation: 'messages:send',
          builder: (context, execute, state) {
            mutate = execute;
            snapshot = state;
            return const SizedBox();
          },
        ),
      ),
    );

    final future = mutate();
    await tester.pump();
    final expectation = expectLater(future, throwsA(isA<StateError>()));
    completer.completeError(StateError('failed'));
    await expectation;
    await tester.pump();

    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasError, isTrue);
    expect(snapshot.error, isA<StateError>());
  });

  testWidgets('ConvexMutation prevents overlapping requests', (tester) async {
    final client = FakeRuntimeClient();
    final completer = Completer<dynamic>();
    client.onMutate = (_, __) => completer.future;

    late ConvexRequestExecutor<String> mutate;

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexMutation<String>(
          mutation: 'messages:send',
          builder: (context, execute, state) {
            mutate = execute;
            return const SizedBox();
          },
        ),
      ),
    );

    final future = mutate();
    await tester.pump();
    expect(() => mutate(), throwsStateError);
    completer.complete('ok');
    await future;
    await tester.pump();
  });

  testWidgets('ConvexAction exposes loading and success state', (tester) async {
    final client = FakeRuntimeClient();
    final completer = Completer<dynamic>();
    client.onAction = (_, __) => completer.future;

    late ConvexRequestExecutor<String> runAction;
    late ConvexRequestSnapshot<String> snapshot;

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexAction<String>(
          action: 'messages:notify',
          builder: (context, execute, state) {
            runAction = execute;
            snapshot = state;
            return const SizedBox();
          },
        ),
      ),
    );

    final future = runAction(const <String, dynamic>{'id': '1'});
    await tester.pump();

    expect(snapshot.isLoading, isTrue);
    expect(client.actionCalls.single.name, 'messages:notify');

    completer.complete('sent');
    expect(await future, 'sent');
    await tester.pump();

    expect(snapshot.hasData, isTrue);
    expect(snapshot.data, 'sent');
  });

  testWidgets('ConvexAction exposes errors', (tester) async {
    final client = FakeRuntimeClient();
    final completer = Completer<dynamic>();
    client.onAction = (_, __) => completer.future;

    late ConvexRequestExecutor<String> runAction;
    late ConvexRequestSnapshot<String> snapshot;

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexAction<String>(
          action: 'messages:notify',
          builder: (context, execute, state) {
            runAction = execute;
            snapshot = state;
            return const SizedBox();
          },
        ),
      ),
    );

    final future = runAction();
    await tester.pump();
    final expectation = expectLater(future, throwsA(isA<StateError>()));
    completer.completeError(StateError('action failed'));
    await expectation;
    await tester.pump();

    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasError, isTrue);
    expect(snapshot.error, isA<StateError>());
  });
}
