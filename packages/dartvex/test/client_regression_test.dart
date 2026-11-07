import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

/// Regression tests for the post-release review fixes in ConvexClient.
void main() {
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  ConvexClient newClient(
    MockWebSocketAdapter adapter, {
    Duration? mutationTimeout,
    DartvexLogger? logger,
    DartvexLogLevel logLevel = DartvexLogLevel.off,
  }) {
    return ConvexClient(
      'https://demo.convex.cloud',
      config: ConvexClientConfig(
        adapterFactory: (_) => adapter,
        reconnectBackoff: const <Duration>[Duration.zero],
        mutationTimeout: mutationTimeout,
        logger: logger,
        logLevel: logLevel,
      ),
    );
  }

  /// Returns the queryId of the most recently added query.
  int lastAddedQueryId(MockWebSocketAdapter adapter) {
    final querySet = adapter.decodedSentMessages
        .where((message) => message['type'] == 'ModifyQuerySet')
        .lastWhere(
          (message) => (message['modifications'] as List<dynamic>).any(
            (modification) =>
                (modification as Map<String, dynamic>)['type'] == 'Add',
          ),
        );
    final add = (querySet['modifications'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .lastWhere((modification) => modification['type'] == 'Add');
    return add['queryId'] as int;
  }

  int querySetVersion(MockWebSocketAdapter adapter) {
    final querySet = adapter.decodedSentMessages
        .where((message) => message['type'] == 'ModifyQuerySet')
        .last;
    return querySet['newVersion'] as int;
  }

  StateVersion version(int querySet, int ts, {int identity = 0}) =>
      StateVersion(querySet: querySet, identity: identity, ts: encodeTs(ts));

  void push(
    MockWebSocketAdapter adapter, {
    required StateVersion start,
    required StateVersion end,
    List<StateModification> modifications = const <StateModification>[],
  }) {
    adapter.pushServerMessage(
      Transition(
        startVersion: start,
        endVersion: end,
        modifications: modifications,
      ).toJson(),
    );
  }

  group('one-shot queries (F6/F11)', () {
    test('a second queryOnce waits for the server instead of the cache',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();

      final first = client.queryOnce<int>('counters:get');
      await settle();
      final firstId = lastAddedQueryId(adapter);
      final firstEnd = version(querySetVersion(adapter), 1);
      push(
        adapter,
        start: const StateVersion.initial(),
        end: firstEnd,
        modifications: <StateModification>[
          QueryUpdated(queryId: firstId, value: 1),
        ],
      );
      expect(await first, 1);
      await settle();

      // The server value changes to 2 while nothing is subscribed.
      var resolved = false;
      final second = client.queryOnce<int>('counters:get')
        ..then((_) => resolved = true);
      await settle();
      expect(resolved, isFalse,
          reason: 'must not resolve from the after-unsubscribe cache');

      final secondId = lastAddedQueryId(adapter);
      push(
        adapter,
        start: firstEnd,
        end: version(querySetVersion(adapter), 2),
        modifications: <StateModification>[
          QueryUpdated(queryId: secondId, value: 2),
        ],
      );
      expect(await second, 2);
      await client.close();
    });

    test('a cached QueryError is not re-thrown without asking the server',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final subscription = client.subscribe('docs:get');
      await settle();
      final firstId = lastAddedQueryId(adapter);
      final firstEnd = version(querySetVersion(adapter), 1);
      push(
        adapter,
        start: const StateVersion.initial(),
        end: firstEnd,
        modifications: <StateModification>[
          QueryFailed(queryId: firstId, errorMessage: 'not found'),
        ],
      );
      await settle();
      subscription.cancel();
      await settle();

      final pending = client.query('docs:get');
      var settled = false;
      pending.then((_) => settled = true, onError: (_) => settled = true);
      await settle();
      expect(settled, isFalse);

      push(
        adapter,
        start: firstEnd,
        end: version(querySetVersion(adapter), 2),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'created'),
        ],
      );
      expect(await pending, 'created');
      await client.close();
    });

    test('query resolves at once from an active subscription', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final subscription = client.subscribe('config:get');
      subscription.stream.listen((_) {});
      await settle();
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'live'),
        ],
      );
      await settle();

      expect(
        await client.query('config:get').timeout(const Duration(seconds: 1)),
        'live',
      );
      subscription.cancel();
      await client.close();
    });

    test('live subscribe() still seeds from the warm cache', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final first = client.subscribe('messages:list');
      final firstValue = first.stream.first;
      await settle();
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'cached'),
        ],
      );
      await firstValue;
      first.cancel();
      await settle();

      final second = client.subscribe('messages:list');
      final seeded =
          await second.stream.first.timeout(const Duration(seconds: 1));
      expect(
        seeded,
        isA<QuerySuccess>().having((result) => result.value, 'value', 'cached'),
      );
      second.cancel();
      await client.close();
    });
  });

  group('queryOnce typing (F154)', () {
    test('a type mismatch is reported as a ConvexException', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final future = client.queryOnce<List<String>>('tags:all');
      await settle();
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(
            queryId: lastAddedQueryId(adapter),
            value: <dynamic>['a', 'b'],
          ),
        ],
      );
      await expectLater(
        future,
        throwsA(
          isA<ConvexException>().having(
            (error) => error.message,
            'message',
            allOf(contains('List<String>'), contains('tags:all')),
          ),
        ),
      );
      await client.close();
    });
  });

  group('multiple listeners (F148)', () {
    test('a second listener also receives the current value', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final subscription = client.subscribe('settings:get');
      final firstValues = <QueryResult>[];
      subscription.stream.listen(firstValues.add);
      await settle();
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'dark'),
        ],
      );
      await settle();
      expect(firstValues, hasLength(1));

      final second =
          await subscription.stream.first.timeout(const Duration(seconds: 1));
      expect(
        second,
        isA<QuerySuccess>().having((result) => result.value, 'value', 'dark'),
      );
      expect(firstValues, hasLength(1));
      subscription.cancel();
      await client.close();
    });
  });

  group('re-entrant emissions (F10/F54/F58/F66)', () {
    test('mutate with a same-query optimistic update from a query listener',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final subscription = client.subscribe('messages:list');
      final values = <Object?>[];
      final errors = <Object>[];
      Future<dynamic>? mutation;
      runZonedGuarded(() {
        subscription.stream.listen((result) {
          if (result is! QuerySuccess) {
            return;
          }
          values.add(result.value);
          if (mutation == null && result.value == 'unread') {
            mutation = client.mutate(
              'messages:markRead',
              const <String, dynamic>{},
              (store) => store.setQuery(
                'messages:list',
                const <String, dynamic>{},
                'read',
              ),
            );
            mutation!.ignore();
          }
        });
      }, (error, _) => errors.add(error));
      await settle();
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'unread'),
        ],
      );
      await settle();

      expect(errors, isEmpty);
      expect(values, <Object?>['unread', 'read']);
      expect(
        adapter.decodedSentMessages
            .where((message) => message['type'] == 'Mutation')
            .map((message) => message['udfPath']),
        <String>['messages:markRead'],
      );
      subscription.cancel();
      await client.close();
    });

    test('mutate from a connectionStatus listener does not throw', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
        ),
      );
      final statuses = <ConnectionStatus>[];
      final errors = <Object>[];
      var sentHeartbeat = false;
      runZonedGuarded(() {
        client.connectionStatus.listen((status) {
          statuses.add(status);
          if (status.isWebSocketConnected && !sentHeartbeat) {
            sentHeartbeat = true;
            client.mutate('presence:heartbeat').ignore();
          }
        });
      }, (error, _) => errors.add(error));

      await client.reconnectNow('start');
      await settle();

      expect(errors, isEmpty);
      expect(sentHeartbeat, isTrue);
      // The status snapshot produced by the nested mutate() is delivered too.
      expect(statuses.any((status) => status.inflightMutations == 1), isTrue);
      expect(
        adapter.decodedSentMessages
            .where((message) => message['type'] == 'Mutation'),
        hasLength(1),
      );
      await client.close();
    });

    test(
        'a precomputed transition event does not overwrite an optimistic '
        'value applied by an earlier listener', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final list = client.subscribe('messages:list');
      final unread = client.subscribe('messages:unreadCount');
      final unreadValues = <Object?>[];
      unread.stream.listen((result) {
        if (result is QuerySuccess) {
          unreadValues.add(result.value);
        }
      });
      list.stream.listen((result) {
        if (result is QuerySuccess && result.value == 'new') {
          client
              .mutate(
                'messages:markRead',
                const <String, dynamic>{},
                (store) => store.setQuery(
                  'messages:unreadCount',
                  const <String, dynamic>{},
                  0,
                ),
              )
              .ignore();
        }
      });
      await settle();
      final adds = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .expand((message) => message['modifications'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((modification) => modification['type'] == 'Add')
          .toList();
      int idOf(int index) => adds[index]['queryId'] as int;
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(queryId: idOf(0), value: 'new'),
          QueryUpdated(queryId: idOf(1), value: 5),
        ],
      );
      await settle();

      expect(unreadValues.last, 0);
      list.cancel();
      unread.cancel();
      await client.close();
    });
  });

  group('auth error during a pause (F44/F65)', () {
    test('a queued action is sent once after a reauth restart', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      await client.setAuth('token-a');
      await settle();

      final tokenFetch = Completer<String?>();
      final authFuture = client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) => tokenFetch.future,
      );
      await settle();
      final action = client.action('payments:charge');
      action.ignore();
      await settle();

      adapter.pushServerMessage(const <String, dynamic>{
        'type': 'AuthError',
        'error': 'expired',
        'baseVersion': 0,
        'authUpdateAttempted': true,
      });
      await settle();
      tokenFetch.complete('token-b');
      await authFuture;
      await settle();
      await settle();

      final charges = adapter.decodedSentMessages
          .where((message) =>
              message['type'] == 'Action' &&
              message['udfPath'] == 'payments:charge')
          .toList();
      expect(charges, hasLength(1));
      await client.close();
    });
  });

  group('close (F57)', () {
    test('a paused listener does not block transport teardown', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final subscription = client.subscribe('messages:list');
      final streamSubscription = subscription.stream.listen((_) {});
      streamSubscription.pause();
      await settle();

      await client.close().timeout(const Duration(seconds: 1));
      expect(adapter.closeCalls, greaterThan(0));
      await streamSubscription.cancel();
    });
  });

  group('fatal errors (F59/F150)', () {
    test('rolls back optimistic layers and fails new requests fast', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final subscription = client.subscribe('todos:list');
      final values = <QueryResult>[];
      subscription.stream.listen(values.add);
      await settle();
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(
            queryId: lastAddedQueryId(adapter),
            value: <String>['a'],
          ),
        ],
      );
      await settle();
      final pending = client.mutate(
        'todos:add',
        const <String, dynamic>{},
        (store) => store.setQuery(
          'todos:list',
          const <String, dynamic>{},
          <String>['a', 'draft'],
        ),
      );
      final failure = expectLater(pending, throwsA(isA<ConvexException>()));
      await settle();

      adapter.pushServerMessage(const <String, dynamic>{
        'type': 'FatalError',
        'error': 'boom',
      });
      await settle();
      await failure;

      // The optimistic layer is rolled back first, then the existing
      // subscriber is told the connection is gone for good.
      final rolledBack = values[values.length - 2] as QuerySuccess;
      expect(rolledBack.value, <String>['a']);
      expect(rolledBack.hasPendingWrites, isFalse);
      expect(
        values.last,
        isA<QueryError>().having(
          (error) => error.message,
          'message',
          contains('fatal server error: boom'),
        ),
      );
      expect(client.currentConnectionState, ConnectionState.fatalError);

      await expectLater(
        client.mutate('todos:add'),
        throwsA(
          isA<ConvexException>().having(
            (error) => error.message,
            'message',
            contains('fatal server error: boom'),
          ),
        ),
      );
      await expectLater(client.action('x:y'), throwsA(isA<ConvexException>()));
      await expectLater(client.query('x:y'), throwsA(isA<ConvexException>()));
      final late = await client
          .subscribe('other:list')
          .stream
          .first
          .timeout(const Duration(seconds: 1));
      expect(late, isA<QueryError>());

      subscription.cancel();
      await client.close();
    });
  });

  group('mutation timeout (F163)', () {
    test('a timeout after the success response resolves with the result',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(
        adapter,
        mutationTimeout: const Duration(milliseconds: 60),
      );
      await settle();
      final future = client.mutate('messages:send');
      await settle();
      final requestId = adapter.decodedSentMessages
          .lastWhere((message) => message['type'] == 'Mutation')['requestId'];
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': requestId,
        'success': true,
        'result': 'committed',
        'ts': encodeTs(99),
        'logLines': const <String>[],
      });

      expect(await future.timeout(const Duration(seconds: 1)), 'committed');
      await client.close();
    });
  });

  group('per-response decode errors (C18)', () {
    test('an undecodable mutation result fails only that mutation', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final other = client.mutate('messages:other');
      final future = client.mutate('messages:send');
      await settle();
      final mutations = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .toList();
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': mutations[1]['requestId'],
        'success': true,
        'result': const <String, dynamic>{r'$futureTag': 'x'},
        'ts': encodeTs(5),
        'logLines': const <String>[],
      });
      await expectLater(future, throwsA(isA<ConvexException>()));
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': mutations[0]['requestId'],
        'success': true,
        'result': const <String, dynamic>{r'$commitTs': null},
        'ts': encodeTs(4),
        'logLines': const <String>[],
      });
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(1, 6),
      );
      expect(
        await other.timeout(const Duration(seconds: 1)),
        same(ConvexCommitTsPlaceholder.instance),
      );
      // The socket was never torn down.
      expect(adapter.connectedUrls, hasLength(1));
      expect(adapter.closeCalls, 0);
      await client.close();
    });
  });

  group('auth entry points after dispose (F155)', () {
    test('report disposal through the returned future', () async {
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: const ConvexClientConfig(connectImmediately: false),
      );
      await client.close();

      await expectLater(client.setAuth('t'), throwsA(isA<ConvexException>()));
      await expectLater(client.clearAuth(), throwsA(isA<ConvexException>()));
      await expectLater(
        client.updateAuthToken('t'),
        throwsA(isA<ConvexException>()),
      );
      await expectLater(
        client.setAuthWithRefresh(
          fetchToken: ({required bool forceRefresh}) async => 't',
        ),
        throwsA(isA<ConvexException>()),
      );
      await expectLater(
        client.reconnectNow('resume'),
        throwsA(isA<ConvexException>()),
      );
    });
  });

  group('connection state (F157)', () {
    test('retries before the first connection report connecting', () async {
      final adapter = _FailingAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration(milliseconds: 5)],
        ),
      );
      final states = <ConnectionState>[];
      client.connectionState.listen(states.add);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(adapter.attempts, greaterThan(1));
      expect(states, isNot(contains(ConnectionState.reconnecting)));
      expect(client.currentConnectionStatus.hasEverConnected, isFalse);
      await client.close();
    });
  });

  group('logging (F149/F230)', () {
    test('a throwing logger does not break message processing', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(
        adapter,
        logLevel: DartvexLogLevel.debug,
        logger: (_) => throw StateError('logger failed'),
      );
      await settle();
      final future = client.query('config:get');
      await settle();
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'ok'),
        ],
      );
      expect(await future.timeout(const Duration(seconds: 1)), 'ok');
      await client.close();
    });

    test('optimistic replay failures are logged', () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final client = newClient(
        adapter,
        logLevel: DartvexLogLevel.warn,
        logger: events.add,
      );
      await settle();
      final subscription = client.subscribe('todos:list');
      subscription.stream.listen((_) {});
      await settle();
      final queryId = lastAddedQueryId(adapter);
      push(
        adapter,
        start: const StateVersion.initial(),
        end: version(querySetVersion(adapter), 1),
        modifications: <StateModification>[
          QueryUpdated(queryId: queryId, value: <String>['a']),
        ],
      );
      await settle();
      var runs = 0;
      client.mutate('todos:add', const <String, dynamic>{}, (store) {
        runs += 1;
        if (runs > 1) {
          throw StateError('replay');
        }
        store.setQuery('todos:list', const <String, dynamic>{}, <String>['b']);
      }).ignore();
      await settle();
      push(
        adapter,
        start: version(querySetVersion(adapter), 1),
        end: version(querySetVersion(adapter), 2),
        modifications: <StateModification>[
          QueryUpdated(queryId: queryId, value: <String>['c']),
        ],
      );
      await settle();

      expect(
        events.where(
          (event) =>
              event.level == DartvexLogLevel.warn &&
              event.message.contains('Optimistic update threw'),
        ),
        hasLength(1),
      );
      subscription.cancel();
      await client.close();
    });
  });

  group('ConvexFunctionCaller (F42/F61)', () {
    test('mutate accepts an optimistic update through the interface', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      final ConvexFunctionCaller caller = client;
      await settle();
      final subscription = client.subscribe('todos:list');
      final values = <QueryResult>[];
      subscription.stream.listen(values.add);
      await settle();
      caller
          .mutate(
            'todos:add',
            const <String, dynamic>{},
            (store) => store.setQuery(
              'todos:list',
              const <String, dynamic>{},
              <String>['draft'],
            ),
          )
          .ignore();
      await settle();
      expect(
        values.last,
        isA<QuerySuccess>().having((result) => result.value, 'value', <String>[
          'draft'
        ]).having((result) => result.hasPendingWrites, 'pending', isTrue),
      );
      subscription.cancel();
      await client.close();
    });
  });
}

/// An adapter whose connection attempts always fail.
class _FailingAdapter extends MockWebSocketAdapter {
  int attempts = 0;

  @override
  Future<void> connect(String url) async {
    attempts += 1;
    throw StateError('connection refused');
  }
}
