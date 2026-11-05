import 'package:dartvex/dartvex.dart'
    show
        ConvexException,
        OptimisticLocalStore,
        QueryError,
        QueryResult,
        QuerySuccess;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FakeConvexClient fidelity', () {
    test('emissions can target one argument set', () async {
      final client = FakeConvexClient();
      final a = <ConvexRuntimeQueryEvent>[];
      final b = <ConvexRuntimeQueryEvent>[];
      client.subscribe('messages:list', {'channel': 'a'}).stream.listen(a.add);
      client.subscribe('messages:list', {'channel': 'b'}).stream.listen(b.add);

      client.emitSubscription(
        'messages:list',
        <String>['a1'],
        args: {'channel': 'a'},
      );
      // Without args, emission stays name-scoped (every subscription).
      client.emitSubscription('messages:list', <String>['all']);

      expect(a.map((e) => (e as ConvexRuntimeQuerySuccess).value), [
        ['a1'],
        ['all'],
      ]);
      expect(b.map((e) => (e as ConvexRuntimeQuerySuccess).value), [
        ['all'],
      ]);
      client.dispose();
    });

    test('loading and pending-write metadata can be emitted', () {
      final client = FakeConvexClient();
      final events = <ConvexRuntimeQueryEvent>[];
      client.subscribe('messages:list').stream.listen(events.add);

      client.emitSubscriptionLoading('messages:list');
      client.emitSubscription(
        'messages:list',
        <String>['optimistic'],
        source: ConvexQuerySource.cache,
        hasPendingWrites: true,
      );

      expect(events.first, isA<ConvexRuntimeQueryLoading>());
      expect(events.first.hasPendingWrites, isTrue);
      expect(events.last.source, ConvexQuerySource.cache);
      expect(events.last.hasPendingWrites, isTrue);
      client.dispose();
    });

    testWidgets('a throwing query handler becomes an error snapshot', (
      tester,
    ) async {
      final client = FakeConvexClient()
        ..whenQueryWith(
          'messages:list',
          (_) => throw const ConvexException('boom'),
        );
      late ConvexQuerySnapshot<Object?> latest;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: ConvexQuery<Object?>(
              query: 'messages:list',
              builder: (context, snapshot) {
                latest = snapshot;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(latest.hasError, isTrue);
      expect(latest.error, isA<ConvexException>());
    });

    test('records calls, including optimistic updates', () async {
      final client = FakeConvexClient()
        ..whenMutation('messages:send', returns: 'id')
        ..whenAction('ai:run', returns: 1)
        ..whenQuery('messages:count', returns: 3);
      void update(OptimisticLocalStore store) {}

      await client.mutate('messages:send', {'text': 'hi'}, update);
      await client.action('ai:run');
      await client.queryOnce<int>('messages:count', {'c': 'a'});

      expect(client.mutationCalls.single.name, 'messages:send');
      expect(client.mutationCalls.single.args, {'text': 'hi'});
      expect(client.mutationCalls.single.optimisticUpdate, same(update));
      expect(client.actionCalls.single.name, 'ai:run');
      expect(client.queryCalls.single.args, {'c': 'a'});
    });

    test('behaves like a disposed client after dispose', () async {
      final client = FakeConvexClient()
        ..whenQuery('q', returns: 1)
        ..whenMutation('m', returns: 1);
      client.dispose();

      expect(() => client.subscribe('q'), throwsA(isA<ConvexException>()));
      expect(
        () => client.paginatedQuery('q', const {}),
        throwsA(isA<ConvexException>()),
      );
      expect(() => client.reconnectNow('x'), throwsA(isA<ConvexException>()));
      await expectLater(client.query('q'), throwsA(isA<ConvexException>()));
      await expectLater(client.mutate('m'), throwsA(isA<ConvexException>()));
      await expectLater(client.action('a'), throwsA(isA<ConvexException>()));
      expect(client.isDisposed, isTrue);
      // Emissions are ignored instead of throwing.
      client.emitSubscription('q', 2);
      client.emitPaginated('q', results: const <dynamic>[]);
    });

    test('paginated queries keep their args and report loadMore like the '
        'real engine', () {
      final client = FakeConvexClient();
      final a =
          client.paginatedQuery('items:list', {'f': 'a'})
              as FakeConvexPaginatedQuery;
      final b =
          client.paginatedQuery('items:list', {'f': 'b'})
              as FakeConvexPaginatedQuery;

      expect(a.args, {'f': 'a'});
      expect(a.loadMore(), isFalse, reason: 'first page still loading');

      client.emitPaginated('items:list', results: const [1], args: {'f': 'a'});
      expect(a.current.results, const [1]);
      expect(b.current.results, isEmpty);
      expect(a.loadMore(50), isTrue);
      expect(a.lastLoadMoreNumItems, 50);
      client.dispose();
    });

    test('functionCaller is backed by the same handlers', () async {
      final client = FakeConvexClient()
        ..whenQuery('messages:list', returns: <String>['m'])
        ..whenMutation('messages:send', returns: 'id');
      final caller = client.functionCaller;

      expect(await caller.query('messages:list'), <String>['m']);
      expect(await caller.mutate('messages:send', {'t': 1}), 'id');
      expect(client.mutationCalls.single.args, {'t': 1});

      final results = <QueryResult>[];
      caller.subscribe('messages:list').stream.listen(results.add);
      await Future<void>.delayed(Duration.zero);
      client.emitSubscriptionError(
        'messages:list',
        const ConvexException('bad'),
      );
      expect((results.first as QuerySuccess).value, <String>['m']);
      expect((results.last as QueryError).message, 'bad');
      expect(
        () => caller.paginatedQuery('x', const {}),
        throwsUnsupportedError,
      );
      client.dispose();
    });
  });
}
