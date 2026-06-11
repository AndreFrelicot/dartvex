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
    await expectLater(mutate(), throwsStateError);
    completer.complete('ok');
    await future;
    await tester.pump();
  });

  testWidgets('ConvexMutation ignores stale completions after widget changes', (
    tester,
  ) async {
    final client = FakeRuntimeClient();
    final firstCompleter = Completer<dynamic>();
    final secondCompleter = Completer<dynamic>();
    client.onMutate = (name, __) {
      if (name == 'messages:first') {
        return firstCompleter.future;
      }
      if (name == 'messages:second') {
        return secondCompleter.future;
      }
      return Future<dynamic>.error(StateError('unexpected mutation $name'));
    };

    late ConvexRequestExecutor<String> mutate;
    late ConvexRequestSnapshot<String> snapshot;

    Widget build(String mutation) {
      return wrapWithProvider(
        client: client,
        child: ConvexMutation<String>(
          mutation: mutation,
          builder: (context, execute, state) {
            mutate = execute;
            snapshot = state;
            return const SizedBox();
          },
        ),
      );
    }

    await tester.pumpWidget(build('messages:first'));
    final firstFuture = mutate();
    await tester.pump();
    expect(snapshot.isLoading, isTrue);

    await tester.pumpWidget(build('messages:second'));
    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasData, isFalse);

    final secondFuture = mutate();
    await tester.pump();
    expect(client.mutateCalls.last.name, 'messages:second');
    expect(snapshot.isLoading, isTrue);

    firstCompleter.complete('stale');
    expect(await firstFuture, 'stale');
    await tester.pump();
    expect(snapshot.isLoading, isTrue);
    expect(snapshot.hasData, isFalse);

    secondCompleter.complete('fresh');
    expect(await secondFuture, 'fresh');
    await tester.pump();
    expect(snapshot.isLoading, isFalse);
    expect(snapshot.data, 'fresh');
  });

  testWidgets('ConvexMutation forwards its optimisticUpdate', (tester) async {
    final client = FakeRuntimeClient();
    client.onMutate = (_, __) async => 'ok';

    void optimistic(OptimisticLocalStore store) {
      store.setQuery(
        'messages:list',
        const <String, dynamic>{},
        const <String>['x'],
      );
    }

    late ConvexRequestExecutor<String> mutate;
    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexMutation<String>(
          mutation: 'messages:send',
          optimisticUpdate: optimistic,
          builder: (context, execute, state) {
            mutate = execute;
            return const SizedBox();
          },
        ),
      ),
    );

    await mutate(const <String, dynamic>{'text': 'hello'});
    await tester.pump();

    expect(client.mutateCalls.single.optimisticUpdate, same(optimistic));
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

  testWidgets('ConvexAction ignores stale completions after widget changes', (
    tester,
  ) async {
    final client = FakeRuntimeClient();
    final firstCompleter = Completer<dynamic>();
    final secondCompleter = Completer<dynamic>();
    client.onAction = (name, __) {
      if (name == 'messages:first') {
        return firstCompleter.future;
      }
      if (name == 'messages:second') {
        return secondCompleter.future;
      }
      return Future<dynamic>.error(StateError('unexpected action $name'));
    };

    late ConvexRequestExecutor<String> runAction;
    late ConvexRequestSnapshot<String> snapshot;

    Widget build(String action) {
      return wrapWithProvider(
        client: client,
        child: ConvexAction<String>(
          action: action,
          builder: (context, execute, state) {
            runAction = execute;
            snapshot = state;
            return const SizedBox();
          },
        ),
      );
    }

    await tester.pumpWidget(build('messages:first'));
    final firstFuture = runAction();
    await tester.pump();
    expect(snapshot.isLoading, isTrue);

    await tester.pumpWidget(build('messages:second'));
    expect(snapshot.isLoading, isFalse);
    expect(snapshot.hasData, isFalse);

    final secondFuture = runAction();
    await tester.pump();
    expect(client.actionCalls.last.name, 'messages:second');
    expect(snapshot.isLoading, isTrue);

    firstCompleter.complete('stale');
    expect(await firstFuture, 'stale');
    await tester.pump();
    expect(snapshot.isLoading, isTrue);
    expect(snapshot.hasData, isFalse);

    secondCompleter.complete('fresh');
    expect(await secondFuture, 'fresh');
    await tester.pump();
    expect(snapshot.isLoading, isFalse);
    expect(snapshot.data, 'fresh');
  });

  testWidgets(
      'ConvexMutation in-flight guard does not report an unhandled error '
      'when the returned future is ignored', (tester) async {
    final client = FakeRuntimeClient();
    final pending = Completer<dynamic>();
    client.onMutate = (name, args) => pending.future;
    late ConvexRequestExecutor<dynamic> mutate;

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexMutation<dynamic>(
          mutation: 'messages:send',
          builder: (context, execute, state) {
            mutate = execute;
            return const SizedBox();
          },
        ),
      ),
    );

    // Double-tap: both returned futures are ignored, as in a plain
    // onPressed handler. The second call hits the in-flight guard.
    unawaited(mutate());
    mutate();
    pending.complete('done');
    await tester.pump();

    expect(client.mutateCalls, hasLength(1));
  });

  testWidgets(
      'ConvexAction in-flight guard does not report an unhandled error '
      'when the returned future is ignored', (tester) async {
    final client = FakeRuntimeClient();
    final pending = Completer<dynamic>();
    client.onAction = (name, args) => pending.future;
    late ConvexRequestExecutor<dynamic> run;

    await tester.pumpWidget(
      wrapWithProvider(
        client: client,
        child: ConvexAction<dynamic>(
          action: 'messages:archive',
          builder: (context, execute, state) {
            run = execute;
            return const SizedBox();
          },
        ),
      ),
    );

    unawaited(run());
    run();
    pending.complete('done');
    await tester.pump();

    expect(client.actionCalls, hasLength(1));
  });
}
