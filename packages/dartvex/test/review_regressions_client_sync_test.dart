import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

/// Regression tests from the 0.3.0 post-release review of the client and sync
/// layers: request flushing around the auth pause, fatal errors reaching
/// existing subscribers, and the scenarios the review checked that held up.
void main() {
  Future<void> settle([int milliseconds = 20]) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  ConvexClient newClient(
    MockWebSocketAdapter adapter, {
    bool expectAuth = false,
  }) =>
      ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          expectAuth: expectAuth,
        ),
      );

  List<Object?> sentTypes(MockWebSocketAdapter adapter) =>
      adapter.decodedSentMessages.map((m) => m['type']).toList();

  List<Map<String, dynamic>> addedQueries(MockWebSocketAdapter adapter) =>
      adapter.decodedSentMessages
          .where((m) => m['type'] == 'ModifyQuerySet')
          .expand(
            (m) => (m['modifications'] as List).cast<Map<String, dynamic>>(),
          )
          .where((m) => m['type'] == 'Add')
          .toList();

  int lastQueryId(MockWebSocketAdapter adapter) =>
      addedQueries(adapter).last['queryId'] as int;

  int querySetVersion(MockWebSocketAdapter adapter) =>
      adapter.decodedSentMessages
          .where((m) => m['type'] == 'ModifyQuerySet')
          .last['newVersion'] as int;

  /// An identity-advancing Transition, as the server sends to confirm auth.
  void pushIdentityTransition(MockWebSocketAdapter adapter) {
    adapter.pushServerMessage(<String, dynamic>{
      'type': 'Transition',
      'startVersion': {'querySet': 0, 'identity': 0, 'ts': 'AAAAAAAAAAA='},
      'endVersion': {'querySet': 0, 'identity': 1, 'ts': 'AQAAAAAAAAA='},
      'modifications': <Object>[],
    });
  }

  group('requests issued around the auth pause', () {
    // While auth holds the pause the adapter may already be open; draining
    // the outgoing queue then raced resume()/prepareReconnect(): the drained
    // request was requeued after they ran, so it was stranded until the next
    // server message, or sent a second time under the same request id.
    for (final pre in <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 10]) {
      test(
          'a mutation and an action issued as the token arrives are sent '
          'once each (pre $pre)', () async {
        final adapter = MockWebSocketAdapter();
        final client = newClient(adapter);
        await settle(10);
        final token = Completer<String?>();
        final auth = client.setAuthWithRefresh(
          fetchToken: ({required bool forceRefresh}) => token.future,
        );
        await settle(10);
        token.complete('tok');
        for (var i = 0; i < pre; i++) {
          await Future<void>.value();
        }
        client.mutate('m:m').ignore();
        client.action('a:a').ignore();
        await auth;
        await settle(10);
        final types = sentTypes(adapter);
        expect(types.where((t) => t == 'Mutation'), hasLength(1),
            reason: 'pre $pre: $types');
        expect(types.where((t) => t == 'Action'), hasLength(1),
            reason: 'pre $pre: $types');
        await client.close();
      });
    }

    test(
        'a mutation queued during the pause goes out on resume, not on the '
        'next server message', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle(10);
      final token = Completer<String?>();
      final auth = client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) => token.future,
      );
      await settle(10);
      token.complete('tok');
      client.mutate('m:m').ignore();
      await auth;
      await settle(300);
      final before = sentTypes(adapter).where((t) => t == 'Mutation').length;
      pushIdentityTransition(adapter);
      await settle(10);
      final after = sentTypes(adapter).where((t) => t == 'Mutation').length;
      expect(<int>[before, after], <int>[1, 1],
          reason: 'before server msg: $before, after: $after; '
              '${sentTypes(adapter)}');
      final types = sentTypes(adapter);
      expect(
          types.indexOf('Mutation'), greaterThan(types.indexOf('Authenticate')),
          reason: '$types');
      await client.close();
    });

    for (final pre in <int>[0, 1, 2, 3, 4, 5, 6, 8]) {
      test(
          'expectAuth: an action issued as the token arrives is sent once '
          '(pre $pre)', () async {
        final adapter = MockWebSocketAdapter();
        final client = newClient(adapter, expectAuth: true);
        await settle(10);
        final token = Completer<String?>();
        final auth = client.setAuthWithRefresh(
          fetchToken: ({required bool forceRefresh}) => token.future,
        );
        await settle(10);
        token.complete('tok');
        for (var i = 0; i < pre; i++) {
          await Future<void>.value();
        }
        client.action('pay:charge').ignore();
        await auth;
        await settle(10);
        pushIdentityTransition(adapter);
        await settle(10);
        final actions = adapter.decodedSentMessages
            .where((m) => m['type'] == 'Action')
            .map((m) => '${m['udfPath']}#${m['requestId']}')
            .toList();
        expect(actions, hasLength(1),
            reason: 'pre $pre: ${sentTypes(adapter)} $actions');
        await client.close();
      });
    }

    test('a reconnect during the token fetch still sends the action once',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle(10);
      final token = Completer<String?>();
      final auth = client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) => token.future,
      );
      await settle(10);
      adapter.disconnect(code: 1006, reason: 'blip');
      await settle(100);
      expect(adapter.isConnected, isTrue, reason: 'mock reconnected');
      token.complete('tok');
      client.action('pay:charge').ignore();
      await auth;
      await settle(10);
      pushIdentityTransition(adapter);
      await settle(10);
      final types = sentTypes(adapter);
      expect(types.where((t) => t == 'Action'), hasLength(1), reason: '$types');
      await client.close();
    });

    test('mutations stay in issue order across the auth resume', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle(10);
      final token = Completer<String?>();
      final auth = client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) => token.future,
      );
      await settle(10);
      token.complete('tok');
      client.mutate('first:m').ignore();
      await auth;
      await settle(10);
      client.mutate('second:m').ignore();
      await settle(10);
      pushIdentityTransition(adapter);
      await settle(10);
      final order = adapter.decodedSentMessages
          .where((m) => m['type'] == 'Mutation')
          .map((m) => m['udfPath'])
          .toList();
      expect(order, <String>['first:m', 'second:m']);
      await client.close();
    });

    void expectOrderedQuerySetAndAuth(
      MockWebSocketAdapter adapter,
      String label,
    ) {
      final sent = adapter.decodedSentMessages;
      final querySets =
          sent.where((m) => m['type'] == 'ModifyQuerySet').toList();
      var expectedBase = 0;
      for (final m in querySets) {
        expect(m['baseVersion'], expectedBase,
            reason: '$label: query-set versions out of order: '
                '${querySets.map((m) => '${m['baseVersion']}->${m['newVersion']}').toList()}');
        expectedBase = m['newVersion'] as int;
      }
      final types = sent.map((m) => m['type']).toList();
      final mutation = types.indexOf('Mutation');
      if (mutation != -1) {
        expect(mutation, greaterThan(types.indexOf('Authenticate')),
            reason: '$label: mutation sent before auth: $types');
      }
    }

    for (final delay in <int>[0, 1, 2, 3, 4, 5, 6, 8]) {
      test(
          'query-set versions stay ordered with a subscribe racing the pause '
          '(delay $delay)', () async {
        final adapter = MockWebSocketAdapter();
        final client = newClient(adapter);
        await settle(10);
        client.subscribe('a:a');
        final auth = client.setAuthWithRefresh(
          fetchToken: ({required bool forceRefresh}) async {
            for (var i = 0; i < delay; i++) {
              await Future<void>.value();
            }
            return 'tok';
          },
        );
        client.subscribe('b:b');
        client.mutate('m:m').ignore();
        await auth;
        await settle(10);
        expectOrderedQuerySetAndAuth(adapter, 'delay $delay');
        expect(addedQueries(adapter).map((m) => m['udfPath']),
            containsAll(<String>['a:a', 'b:b']));
        expect(sentTypes(adapter).where((t) => t == 'Mutation'), hasLength(1),
            reason: 'mutation not sent after resume');
        await client.close();
      });
    }

    final entryPoints = <String, Future<void> Function(ConvexClient)>{
      'setAuth': (c) => c.setAuth('tok'),
      'setAuth(null)': (c) => c.setAuth(null),
      'clearAuth': (c) => c.clearAuth(),
      'setAuthWithRefresh': (c) => c.setAuthWithRefresh(
            fetchToken: ({required bool forceRefresh}) async => 'tok',
          ),
      'setAuthWithRefresh(null token)': (c) => c
          .setAuthWithRefresh(
            fetchToken: ({required bool forceRefresh}) async => null,
          )
          .then((_) {}, onError: (_) {}),
      'updateAuthToken': (c) => c.updateAuthToken('tok'),
    };
    for (final entry in entryPoints.entries) {
      test('expectAuth is released by ${entry.key}', () async {
        final adapter = MockWebSocketAdapter();
        final client = newClient(adapter, expectAuth: true);
        client.subscribe('q:q');
        client.mutate('m:m').ignore();
        await settle();
        final before = sentTypes(adapter);
        expect(before.where((t) => t == 'Mutation'), isEmpty,
            reason: 'leaked before auth: $before');
        await entry.value(client);
        await settle();
        final types = sentTypes(adapter);
        expect(types, contains('Mutation'), reason: '${entry.key}: $types');
        expect(types, contains('ModifyQuerySet'),
            reason: '${entry.key}: $types');
        final auth = types.indexOf('Authenticate');
        if (auth != -1) {
          expect(types.indexOf('Mutation'), greaterThan(auth),
              reason: '${entry.key}: $types');
        }
        await client.close();
      });
    }
  });

  group('a send failure on a slow-closing socket', () {
    /// Fails the send of the first action on a socket whose close handshake
    /// is slow, then waits until the client-initiated reconnect (100ms base)
    /// has replayed the unsent action on a new socket, before the old
    /// socket's close completes.
    Future<(_FailingSendAdapter, ConvexClient, Future<dynamic>)>
        failActionSendThenReconnect() async {
      final adapter = _FailingSendAdapter();
      final client = newClient(adapter);
      await settle(10);
      adapter.failNextActionSend = true;
      adapter.closeGate = Completer<void>();
      final action = client.action('pay:charge');
      action.ignore();
      await settle(400);
      expect(adapter.connectedUrls, hasLength(2), reason: 'reconnected');
      expect(sentTypes(adapter).where((t) => t == 'Action'), hasLength(1),
          reason: 'the reconnect replays the unsent action');
      return (adapter, client, action);
    }

    test(
        'the late cleanup of the failed socket does not tear down the '
        'connection that already replaced it', () async {
      final (adapter, client, action) = await failActionSendThenReconnect();
      final states = <ConnectionState>[];
      client.connectionState.listen(states.add);

      // The old socket's close handshake finally completes.
      adapter.closeGate!.complete();
      await settle(300);

      expect(adapter.connectedUrls, hasLength(2),
          reason: 'a third connect tore down the replacement socket');
      expect(adapter.isConnected, isTrue);
      expect(client.currentConnectionState, ConnectionState.connected);
      expect(states, isNot(contains(ConnectionState.reconnecting)));

      // The action sent on the replacement socket is still in flight, not
      // failed as lost, and resolves with the server's response.
      final requestId = adapter.decodedSentMessages
          .lastWhere((m) => m['type'] == 'Action')['requestId'];
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'ActionResponse',
        'requestId': requestId,
        'success': true,
        'result': 'charged',
        'logLines': const <String>[],
      });
      expect(await action.timeout(const Duration(seconds: 1)), 'charged');
      await client.close();
    });

    test(
        'a request whose send failed is not requeued on top of the reconnect '
        'that already replays it', () async {
      // Guards the outgoing-generation check in the flush: once the slow
      // close returns, requeueing (and re-flushing) the stale remainder would
      // send the action a second time, under the same request id, on the
      // replacement socket.
      final (adapter, client, action) = await failActionSendThenReconnect();
      adapter.closeGate!.complete();
      await settle(10);
      // The next flush drains whatever is queued.
      client.mutate('other:m').ignore();
      await settle(10);
      final actions = adapter.decodedSentMessages
          .where((m) => m['type'] == 'Action')
          .map((m) => '${m['udfPath']}#${m['requestId']}')
          .toList();
      expect(actions, <String>['pay:charge#0'],
          reason: '${sentTypes(adapter)}');
      expect(adapter.connectedUrls, hasLength(2));
      await client.close();
    });
  });

  group('a FatalError reaches existing subscribers', () {
    void pushFatal(MockWebSocketAdapter adapter) {
      adapter.pushServerMessage(const <String, dynamic>{
        'type': 'FatalError',
        'error': 'boom',
      });
    }

    test('a pending one-shot query() rejects', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle(10);
      final pending = client.query('todos:list');
      Object? outcome;
      pending.then((v) => outcome = v, onError: (Object e) => outcome = e);
      await settle(10);

      pushFatal(adapter);
      await settle(10);
      expect(client.currentConnectionState, ConnectionState.fatalError);
      await settle(200);
      expect(
        outcome,
        isA<ConvexException>().having(
          (error) => error.message,
          'message',
          contains('fatal server error: boom'),
        ),
        reason: 'query() issued before the FatalError never completes',
      );
      await client.close();
    });

    test('a live subscription receives a QueryError', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle(10);
      final events = <QueryResult>[];
      client.subscribe('todos:list').stream.listen(events.add);
      await settle(10);
      pushFatal(adapter);
      await settle(200);
      expect(events.whereType<QueryError>(), isNotEmpty,
          reason: 'existing subscribers stay loading forever');
      await client.close();
    });

    test('a paginated query moves to the error status', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle(10);
      final paginated =
          client.paginatedQuery('todos:page', const <String, dynamic>{});
      await settle(10);
      pushFatal(adapter);
      await settle(200);
      expect(paginated.status, ConvexPaginationStatus.error,
          reason: 'paginated query stays loadingFirstPage forever');
      await client.close();
    });

    test(
        'a listener re-entering the client during the fatal delivery keeps '
        'every listener informed', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle(10);
      final first = <QueryResult>[];
      final second = <QueryResult>[];
      final sub = client.subscribe('todos:list');
      sub.stream.listen((event) {
        first.add(event);
        if (event is QueryError) {
          // Re-entrant: a new subscription seeds from the dispatch queue.
          client.subscribe('other:list').stream.listen(second.add);
        }
      });
      await settle(10);
      pushFatal(adapter);
      await settle(50);
      expect(first.whereType<QueryError>(), hasLength(1));
      expect(second.whereType<QueryError>(), isNotEmpty);
      await client.close();
    });
  });

  group('scenarios the review checked that held up', () {
    test('an undecodable query value fails only that query', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final events = <QueryResult>[];
      client.subscribe('docs:get').stream.listen(events.add);
      await settle();
      final qs = adapter.decodedSentMessages
          .lastWhere((m) => m['type'] == 'ModifyQuerySet');
      final queryId = ((qs['modifications'] as List).first as Map)['queryId'];
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'Transition',
        'startVersion': {'querySet': 0, 'identity': 0, 'ts': 'AAAAAAAAAAA='},
        'endVersion': {
          'querySet': qs['newVersion'],
          'identity': 0,
          'ts': 'AQAAAAAAAAA=',
        },
        'modifications': [
          {
            'type': 'QueryUpdated',
            'queryId': queryId,
            'value': {r'$futureTag': 'x'},
            'logLines': <String>[],
            'journal': null,
          },
        ],
      });
      await settle(200);
      expect(adapter.closeCalls, 0,
          reason: 'the whole socket was torn down for one bad query value');
      expect(events.whereType<QueryError>(), isNotEmpty);
      await client.close();
    });

    test('close() and mutate() from inside a query listener', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final sub = client.subscribe('todos:list');
      final b = <QueryResult>[];
      var bDone = false;
      Future<dynamic>? pending;
      sub.stream.listen((event) {
        if (event is QuerySuccess && event.value == 1) {
          pending = client.mutate(
            'todos:add',
            const <String, dynamic>{},
            (store) =>
                store.setQuery('todos:list', const <String, dynamic>{}, 2),
          );
          pending!.ignore();
          client.close();
        }
      });
      sub.stream.listen(b.add, onDone: () => bDone = true);
      await settle();
      adapter.pushServerMessage(Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(
          querySet: querySetVersion(adapter),
          identity: 0,
          ts: encodeTs(1),
        ),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastQueryId(adapter), value: 1),
        ],
      ).toJson());
      await settle();
      expect(bDone, isTrue);
      await expectLater(pending, throwsA(isA<ConvexException>()));
      // The second listener saw the server value in the same delivery.
      expect(b.whereType<QuerySuccess>().map((e) => e.value), contains(1));
    });

    test('a second listener gets the current value even mid re-entrant chain',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final sub = client.subscribe('todos:list');
      final late = <QueryResult>[];
      sub.stream.listen((event) {
        if (event is QuerySuccess && event.value == 1) {
          client
              .mutate(
                'todos:add',
                const <String, dynamic>{},
                (store) =>
                    store.setQuery('todos:list', const <String, dynamic>{}, 2),
              )
              .ignore();
          sub.stream.listen(late.add);
        }
      });
      await settle();
      adapter.pushServerMessage(Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(
          querySet: querySetVersion(adapter),
          identity: 0,
          ts: encodeTs(1),
        ),
        modifications: <StateModification>[
          QueryUpdated(queryId: lastQueryId(adapter), value: 1),
        ],
      ).toJson());
      await settle();
      expect(late.whereType<QuerySuccess>().last.value, 2);
      expect(late.whereType<QuerySuccess>().last.hasPendingWrites, isTrue);
      await client.close();
    });

    test('client close completes the paginated stream', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final paginated =
          client.paginatedQuery('todos:page', const <String, dynamic>{});
      final done = Completer<void>();
      paginated.stream.listen((_) {}, onDone: done.complete);
      await settle();
      await client.close();
      await done.future.timeout(const Duration(seconds: 1));
      expect(paginated.status, ConvexPaginationStatus.error);
    });

    test('InvalidCursor on page 2 resets and reloads page 1', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final paginated = client.paginatedQuery(
        'todos:page',
        const <String, dynamic>{},
        pageSize: 1,
      );
      await settle();
      var ts = 1;
      var start = const StateVersion.initial();
      void push(List<StateModification> mods) {
        final end = StateVersion(
          querySet: querySetVersion(adapter),
          identity: 0,
          ts: encodeTs(ts++),
        );
        adapter.pushServerMessage(Transition(
          startVersion: start,
          endVersion: end,
          modifications: mods,
        ).toJson());
        start = end;
      }

      push(<StateModification>[
        QueryUpdated(queryId: lastQueryId(adapter), value: {
          'page': <Object>['a'],
          'isDone': false,
          'continueCursor': 'c1',
        }),
      ]);
      await settle();
      expect(paginated.status, ConvexPaginationStatus.canLoadMore);
      expect(paginated.loadMore(), isTrue);
      await settle();
      push(<StateModification>[
        QueryFailed(
          queryId: lastQueryId(adapter),
          errorMessage: 'InvalidCursor: bad',
        ),
      ]);
      await settle();
      final last = addedQueries(adapter).last;
      final opts = (last['args'] as List).first['paginationOpts'] as Map;
      expect(opts['cursor'], isNull);
      expect(opts['id'], isNotNull);
      expect(paginated.status, ConvexPaginationStatus.loadingFirstPage);
      paginated.cancel();
      await client.close();
    });

    test('an out-of-order Transition reconnects and the session recovers',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          initialBackoff: Duration.zero,
          maxBackoff: Duration.zero,
        ),
      );
      await settle();
      final events = <QueryResult>[];
      client.subscribe('q:q').stream.listen(events.add);
      final mutation = client.mutate('m:m');
      await settle();
      // Wrong start version: the sync layer asks for a reconnect.
      adapter.pushServerMessage(Transition(
        startVersion: StateVersion(querySet: 5, identity: 0, ts: encodeTs(5)),
        endVersion: StateVersion(querySet: 6, identity: 0, ts: encodeTs(6)),
        modifications: const <StateModification>[],
      ).toJson());
      await settle(300);
      expect(adapter.connectedUrls.length, greaterThanOrEqualTo(2));
      final sent = adapter.decodedSentMessages;
      expect(sent.where((m) => m['type'] == 'Connect'), hasLength(2));
      final lastConnect = sent.lastIndexWhere((m) => m['type'] == 'Connect');
      final afterReconnect = sent.sublist(lastConnect);
      expect(afterReconnect.map((m) => m['type']),
          containsAll(<String>['ModifyQuerySet', 'Mutation']));
      final qs =
          afterReconnect.firstWhere((m) => m['type'] == 'ModifyQuerySet');
      final queryId = ((qs['modifications'] as List).first as Map)['queryId'];
      final requestId = afterReconnect
          .firstWhere((m) => m['type'] == 'Mutation')['requestId'];
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': requestId,
        'success': true,
        'result': 'ok',
        'ts': encodeTs(10),
        'logLines': const <String>[],
      });
      adapter.pushServerMessage(Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(10)),
        modifications: <StateModification>[
          QueryUpdated(queryId: queryId as int, value: 42),
        ],
      ).toJson());
      expect(await mutation.timeout(const Duration(seconds: 1)), 'ok');
      await settle();
      expect(
          events.whereType<QuerySuccess>().map((e) => e.value), contains(42));
      await client.close();
    });
  });
}

/// Throws from send() for the next `Action` frame (as a socket failing
/// mid-send would) and completes close() only once [closeGate] is released.
class _FailingSendAdapter extends MockWebSocketAdapter {
  bool failNextActionSend = false;
  Completer<void>? closeGate;

  @override
  void send(String message) {
    if (failNextActionSend && message.contains('"type":"Action"')) {
      failNextActionSend = false;
      throw StateError('send failed');
    }
    super.send(message);
  }

  @override
  Future<void> close() async {
    final gate = closeGate;
    await super.close();
    if (gate != null) {
      await gate.future;
    }
  }
}
