import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FakeConvexClient', () {
    test('whenQuery returns mocked data', () async {
      final client = FakeConvexClient()
        ..whenQuery('messages:list', returns: ['msg1', 'msg2']);

      final result = await client.query('messages:list');
      expect(result, ['msg1', 'msg2']);
    });

    test('whenQueryWith returns dynamic data based on args', () async {
      final client = FakeConvexClient()
        ..whenQueryWith('messages:list', (args) {
          return ['msg-${args['channel']}'];
        });

      final result = await client.query(
        'messages:list',
        {'channel': 'general'},
      );
      expect(result, ['msg-general']);
    });

    test('whenMutation returns mocked data', () async {
      final client = FakeConvexClient()
        ..whenMutation('messages:send', returns: {'id': 'abc123'});

      final result = await client.mutate('messages:send', {'text': 'hello'});
      expect(result, {'id': 'abc123'});
    });

    test('whenAction returns mocked data', () async {
      final client = FakeConvexClient()
        ..whenAction('files:generateUploadUrl',
            returns: 'https://upload.convex.cloud/abc');

      final result = await client.action('files:generateUploadUrl');
      expect(result, 'https://upload.convex.cloud/abc');
    });

    test('query throws when no handler registered', () {
      final client = FakeConvexClient();
      expect(
        () => client.query('missing:query'),
        throwsA(isA<StateError>()),
      );
    });

    test('queryOnce returns typed result', () async {
      final client = FakeConvexClient()
        ..whenQuery('config:get', returns: 'production');

      final result = await client.queryOnce<String>('config:get');
      expect(result, 'production');
    });

    test('subscribe auto-emits from query handler', () async {
      final client = FakeConvexClient()
        ..whenQuery('messages:list', returns: ['msg1']);

      final subscription = client.subscribe('messages:list');
      final event = await subscription.stream.first;

      expect(event, isA<ConvexRuntimeQuerySuccess>());
      expect((event as ConvexRuntimeQuerySuccess).value, ['msg1']);
    });

    test('emitSubscription pushes updates', () async {
      final client = FakeConvexClient();
      final subscription = client.subscribe('messages:list');

      final events = <ConvexRuntimeQueryEvent>[];
      subscription.stream.listen(events.add);

      client.emitSubscription('messages:list', ['msg1']);
      client.emitSubscription('messages:list', ['msg1', 'msg2']);

      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(
        (events[0] as ConvexRuntimeQuerySuccess).value,
        ['msg1'],
      );
      expect(
        (events[1] as ConvexRuntimeQuerySuccess).value,
        ['msg1', 'msg2'],
      );
    });

    test('emitSubscription broadcasts to duplicate subscriptions', () async {
      final client = FakeConvexClient();
      final first = client.subscribe('messages:list');
      final second = client.subscribe('messages:list');

      final firstEvents = <ConvexRuntimeQueryEvent>[];
      final secondEvents = <ConvexRuntimeQueryEvent>[];
      first.stream.listen(firstEvents.add);
      second.stream.listen(secondEvents.add);

      client.emitSubscription('messages:list', ['msg1']);

      await Future<void>.delayed(Duration.zero);

      expect(firstEvents, hasLength(1));
      expect(secondEvents, hasLength(1));
      expect((firstEvents.single as ConvexRuntimeQuerySuccess).value, ['msg1']);
      expect((secondEvents.single as ConvexRuntimeQuerySuccess).value, [
        'msg1',
      ]);
    });

    test('emitSubscriptionError pushes error events', () async {
      final client = FakeConvexClient();
      final subscription = client.subscribe('messages:list');

      final events = <ConvexRuntimeQueryEvent>[];
      subscription.stream.listen(events.add);

      client.emitSubscriptionError('messages:list', StateError('boom'));

      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events[0], isA<ConvexRuntimeQueryError>());
    });

    test('emitConnectionState updates connection state', () async {
      final client = FakeConvexClient();
      expect(
        client.currentConnectionState,
        ConvexConnectionState.connected,
      );

      final states = <ConvexConnectionState>[];
      client.connectionState.listen(states.add);

      client.emitConnectionState(ConvexConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);

      expect(states, [ConvexConnectionState.disconnected]);
      expect(
        client.currentConnectionState,
        ConvexConnectionState.disconnected,
      );
    });

    test('emit helpers are no-ops after dispose', () {
      final client = FakeConvexClient();
      client.dispose();

      expect(
        () => client.emitConnectionState(ConvexConnectionState.disconnected),
        returnsNormally,
      );
      expect(
        () => client.emitConnectionStatus(
          ConnectionStatus.fromState(ConvexConnectionState.connected),
        ),
        returnsNormally,
      );
      expect(() => client.emitAuthRefreshing(true), returnsNormally);
    });

    testWidgets('works with ConvexQuery widget', (tester) async {
      final client = FakeConvexClient()
        ..whenQuery('messages:list', returns: 'hello from fake');

      late ConvexQuerySnapshot<String> snapshot;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexProvider(
            client: client,
            child: ConvexQuery<String>(
              query: 'messages:list',
              builder: (context, snap) {
                snapshot = snap;
                return Text(snap.hasData ? snap.data! : 'loading');
              },
            ),
          ),
        ),
      );

      await tester.pump();

      expect(snapshot.hasData, isTrue);
      expect(snapshot.data, 'hello from fake');
    });

    test('paginatedQuery emits results and records loadMore', () async {
      final client = FakeConvexClient();
      final query = client.paginatedQuery(
        'messages:list',
        const <String, dynamic>{},
        pageSize: 2,
      );

      expect(query.current.status, ConvexPaginationStatus.loadingFirstPage);

      final results = <ConvexPaginatedResult>[];
      query.stream.listen(results.add);

      client.emitPaginated(
        'messages:list',
        results: <dynamic>['a', 'b'],
        status: ConvexPaginationStatus.canLoadMore,
      );
      await Future<void>.delayed(Duration.zero);

      expect(query.current.results, <dynamic>['a', 'b']);
      expect(results.single.status, ConvexPaginationStatus.canLoadMore);

      expect(query.loadMore(), isTrue);
      expect((query as FakeConvexPaginatedQuery).loadMoreCount, 1);

      client.dispose();
    });

    test('emitPaginated broadcasts to duplicate paginated queries', () async {
      final client = FakeConvexClient();
      final first = client.paginatedQuery(
        'messages:list',
        const <String, dynamic>{},
      );
      final second = client.paginatedQuery(
        'messages:list',
        const <String, dynamic>{},
      );

      final firstResults = <ConvexPaginatedResult>[];
      final secondResults = <ConvexPaginatedResult>[];
      first.stream.listen(firstResults.add);
      second.stream.listen(secondResults.add);

      client.emitPaginated(
        'messages:list',
        results: <dynamic>['a'],
        status: ConvexPaginationStatus.exhausted,
        isDone: true,
      );
      await Future<void>.delayed(Duration.zero);

      expect(firstResults, hasLength(1));
      expect(secondResults, hasLength(1));
      expect(first.current.results, <dynamic>['a']);
      expect(second.current.results, <dynamic>['a']);

      client.dispose();
    });
  });
}
