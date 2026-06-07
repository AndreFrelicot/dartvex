import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

void main() {
  group('ConvexClient', () {
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    Future<void> waitForStatus(
      ConvexClient client,
      bool Function(ConnectionStatus status) matches,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (DateTime.now().isBefore(deadline)) {
        if (matches(client.currentConnectionStatus)) {
          return;
        }
        await settle();
      }
      fail(
        'Timed out waiting for connection status. '
        'Last status: ${client.currentConnectionStatus}',
      );
    }

    test('accepts empty reconnect backoff (selects exponential mode)', () {
      expect(
        () => ConvexClient(
          'https://demo.convex.cloud',
          config: const ConvexClientConfig(
            connectImmediately: false,
            reconnectBackoff: <Duration>[],
          ),
        ),
        returnsNormally,
      );
    });

    test('defaults inactivity timeout to official 60 second threshold', () {
      expect(
        const ConvexClientConfig().inactivityTimeout,
        const Duration(seconds: 60),
      );
    });

    test('rejects negative reconnect backoff entries', () {
      expect(
        () => ConvexClient(
          'https://demo.convex.cloud',
          config: const ConvexClientConfig(
            connectImmediately: false,
            reconnectBackoff: <Duration>[Duration(milliseconds: -1)],
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'config.reconnectBackoff',
          ),
        ),
      );
    });

    test('rejects invalid timing and reconnect config values', () {
      final cases = <({String name, ConvexClientConfig config})>[
        (
          name: 'config.refreshTokenLeewaySeconds',
          config: const ConvexClientConfig(
            connectImmediately: false,
            refreshTokenLeewaySeconds: -1,
          ),
        ),
        (
          name: 'config.inactivityTimeout',
          config: const ConvexClientConfig(
            connectImmediately: false,
            inactivityTimeout: Duration.zero,
          ),
        ),
        (
          name: 'config.connectTimeout',
          config: const ConvexClientConfig(
            connectImmediately: false,
            connectTimeout: Duration.zero,
          ),
        ),
        (
          name: 'config.queryTimeout',
          config: const ConvexClientConfig(
            connectImmediately: false,
            queryTimeout: Duration.zero,
          ),
        ),
        (
          name: 'config.mutationTimeout',
          config: const ConvexClientConfig(
            connectImmediately: false,
            mutationTimeout: Duration(milliseconds: -1),
          ),
        ),
        (
          name: 'config.actionTimeout',
          config: const ConvexClientConfig(
            connectImmediately: false,
            actionTimeout: Duration.zero,
          ),
        ),
        (
          name: 'config.initialBackoff',
          config: const ConvexClientConfig(
            connectImmediately: false,
            initialBackoff: Duration(milliseconds: -1),
          ),
        ),
        (
          name: 'config.maxBackoff',
          config: const ConvexClientConfig(
            connectImmediately: false,
            maxBackoff: Duration(milliseconds: -1),
          ),
        ),
        (
          name: 'config.maxBackoff',
          config: const ConvexClientConfig(
            connectImmediately: false,
            initialBackoff: Duration(seconds: 2),
            maxBackoff: Duration(seconds: 1),
          ),
        ),
        (
          name: 'config.backoffJitter',
          config: const ConvexClientConfig(
            connectImmediately: false,
            backoffJitter: -0.1,
          ),
        ),
        (
          name: 'config.backoffJitter',
          config: const ConvexClientConfig(
            connectImmediately: false,
            backoffJitter: 1.1,
          ),
        ),
        (
          name: 'config.backoffJitter',
          config: ConvexClientConfig(
            connectImmediately: false,
            backoffJitter: double.nan,
          ),
        ),
      ];

      for (final entry in cases) {
        expect(
          () => ConvexClient(
            'https://demo.convex.cloud',
            config: entry.config,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'name',
              entry.name,
            ),
          ),
          reason: entry.name,
        );
      }
    });

    test('rejects deployment URLs without an absolute supported scheme', () {
      expect(
        () => ConvexClient(
          'demo.convex.cloud',
          config: const ConvexClientConfig(connectImmediately: false),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'deploymentUrl',
          ),
        ),
      );
    });

    test('rejects deployment URLs with path query or fragment', () {
      for (final deploymentUrl in <String>[
        'https://demo.convex.cloud/api',
        'https://demo.convex.cloud?token=secret',
        'https://demo.convex.cloud#fragment',
      ]) {
        expect(
          () => ConvexClient(
            deploymentUrl,
            config: const ConvexClientConfig(connectImmediately: false),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'name',
              'deploymentUrl',
            ),
          ),
        );
      }
    });

    test('normalizes trailing slash deployment URL', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud/',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      final subscription = client.subscribe('messages:list');
      await settle();

      expect(
        adapter.connectedUrls.single,
        'wss://demo.convex.cloud/api/1.40.0/sync',
      );

      subscription.cancel();
      client.dispose();
    });

    test('preserves ws scheme when building WebSocket URL', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'ws://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      final subscription = client.subscribe('messages:list');
      await settle();

      expect(adapter.connectedUrls.single, startsWith('ws://'));

      subscription.cancel();
      client.dispose();
    });

    test('lazy config does not connect in constructor', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      expect(adapter.connectedUrls, isEmpty);
      expect(client.currentConnectionState, ConnectionState.disconnected);
      client.dispose();
    });

    test('first lazy subscribe starts socket and flushes query add', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      final subscription = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      await settle();

      expect(adapter.connectedUrls, hasLength(1));
      expect(
        adapter.decodedSentMessages.map((message) => message['type']),
        containsAllInOrder(<String>['Connect', 'ModifyQuerySet']),
      );

      subscription.cancel();
      client.dispose();
    });

    test('first lazy mutation starts socket and sends mutation', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      final future = client.mutate('messages:send',
          const <String, dynamic>{'body': 'hello'}).catchError((_) {});
      await settle();

      expect(adapter.connectedUrls, hasLength(1));
      expect(
        adapter.decodedSentMessages.map((message) => message['type']),
        containsAllInOrder(<String>['Connect', 'Mutation']),
      );

      client.dispose();
      await future;
    });

    test('failed optimistic update does not leave mutation queued', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      await expectLater(
        client.mutate(
          'messages:bad',
          const <String, dynamic>{'body': 'bad'},
          (_) => throw StateError('bad optimistic update'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'bad optimistic update',
          ),
        ),
      );

      final future = client.mutate('messages:send',
          const <String, dynamic>{'body': 'ok'}).catchError((_) {});
      await settle();

      final mutationMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .toList(growable: false);
      expect(mutationMessages, hasLength(1));
      expect(
        (mutationMessages.single['args'] as List<dynamic>).single,
        const <String, dynamic>{'body': 'ok'},
      );

      client.dispose();
      await future;
    });

    test('first lazy action starts socket and sends action', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      final future = client.action('messages:notify',
          const <String, dynamic>{'body': 'hello'}).catchError((_) {});
      await settle();

      expect(adapter.connectedUrls, hasLength(1));
      expect(
        adapter.decodedSentMessages.map((message) => message['type']),
        containsAllInOrder(<String>['Connect', 'Action']),
      );

      client.dispose();
      await future;
    });

    test('lazy auth starts socket and replays auth on connect', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      await client.setAuth('jwt-token');
      await settle();

      expect(adapter.connectedUrls, hasLength(1));
      expect(
        adapter.decodedSentMessages.map((message) => message['type']),
        containsAllInOrder(<String>['Connect', 'Authenticate']),
      );
      final auth = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Authenticate')
          .single;
      expect(auth['tokenType'], 'User');
      expect(auth['value'], 'jwt-token');

      client.dispose();
    });

    test('lazy reconnectNow starts socket', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectImmediately: false,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );

      await client.reconnectNow('AppResumed');
      await settle();

      expect(adapter.connectedUrls, hasLength(1));
      expect(adapter.decodedSentMessages.single['type'], 'Connect');

      client.dispose();
    });

    test('subscribe receives query updates', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final subscription = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      final future = subscription.stream.first;
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: 'hello'),
          ],
        ).toJson(),
      );

      expect(await future, isA<QuerySuccess>());
      client.dispose();
    });

    test('paginatedQuery sends paginationOpts and aggregates pages reactively',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final query = client.paginatedQuery(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
        pageSize: 2,
      );
      addTearDown(query.cancel);
      await settle();

      // The first page subscribes with paginationOpts {numItems, cursor: null}.
      Map<String, dynamic> lastAdd() {
        final querySet = adapter.decodedSentMessages
            .where((message) => message['type'] == 'ModifyQuerySet')
            .last;
        return (querySet['modifications'] as List<dynamic>).single
            as Map<String, dynamic>;
      }

      final firstAdd = lastAdd();
      final firstQueryId = firstAdd['queryId'] as int;
      final firstArgs =
          (firstAdd['args'] as List<dynamic>).single as Map<String, dynamic>;
      expect(firstArgs['channel'], 'general');
      expect(
        firstArgs['paginationOpts'],
        <String, dynamic>{'numItems': 2, 'cursor': null},
      );

      final version1 = StateVersion(querySet: 1, identity: 0, ts: encodeTs(1));
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: version1,
          modifications: <StateModification>[
            QueryUpdated(
              queryId: firstQueryId,
              value: const <String, dynamic>{
                'page': <dynamic>['a', 'b'],
                'continueCursor': 'cursor-1',
                'isDone': false,
              },
            ),
          ],
        ).toJson(),
      );
      await settle();
      expect(query.current.results, <dynamic>['a', 'b']);
      expect(query.current.status, ConvexPaginationStatus.canLoadMore);

      // loadMore chains the second page from the first page's continueCursor.
      expect(query.loadMore(), isTrue);
      await settle();
      final secondAdd = lastAdd();
      final secondQueryId = secondAdd['queryId'] as int;
      final secondArgs =
          (secondAdd['args'] as List<dynamic>).single as Map<String, dynamic>;
      expect(
        secondArgs['paginationOpts'],
        <String, dynamic>{'numItems': 2, 'cursor': 'cursor-1'},
      );

      final version2 = StateVersion(querySet: 2, identity: 0, ts: encodeTs(2));
      adapter.pushServerMessage(
        Transition(
          startVersion: version1,
          endVersion: version2,
          modifications: <StateModification>[
            QueryUpdated(
              queryId: secondQueryId,
              value: const <String, dynamic>{
                'page': <dynamic>['c', 'd'],
                'continueCursor': 'cursor-2',
                'isDone': true,
              },
            ),
          ],
        ).toJson(),
      );
      await settle();
      expect(query.current.results, <dynamic>['a', 'b', 'c', 'd']);
      expect(query.current.status, ConvexPaginationStatus.exhausted);
      expect(query.isDone, isTrue);

      // A reactive change to the FIRST page flows through with no gap/dupe.
      adapter.pushServerMessage(
        Transition(
          startVersion: version2,
          endVersion: StateVersion(querySet: 2, identity: 0, ts: encodeTs(3)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: firstQueryId,
              value: const <String, dynamic>{
                'page': <dynamic>['a', 'a2', 'b'],
                'continueCursor': 'cursor-1',
                'isDone': false,
              },
            ),
          ],
        ).toJson(),
      );
      await settle();
      expect(query.current.results, <dynamic>['a', 'a2', 'b', 'c', 'd']);
      expect(query.current.status, ConvexPaginationStatus.exhausted);

      client.dispose();
    });

    test('paginatedQuery seeds synchronously from warm query cache', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://example.com',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final pageArgs = <String, dynamic>{
        'channel': 'general',
        'paginationOpts': <String, dynamic>{
          'numItems': 2,
          'cursor': null,
        },
      };
      final warmSubscription = client.subscribe('messages:list', pageArgs);
      await settle();
      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: queryId,
              value: const <String, dynamic>{
                'page': <String>['warm'],
                'continueCursor': 'C',
                'isDone': false,
              },
            ),
          ],
        ).toJson(),
      );
      await settle();
      warmSubscription.cancel();
      await settle();

      final query = client.paginatedQuery(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
        pageSize: 2,
      );

      expect(query.current.results, <dynamic>['warm']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);

      query.cancel();
      client.dispose();
    });

    test(
        'paginatedQuery does not seed stale cache while optimistically loading',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://example.com',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final pageArgs = <String, dynamic>{
        'channel': 'general',
        'paginationOpts': <String, dynamic>{
          'numItems': 2,
          'cursor': null,
        },
      };
      final warmSubscription = client.subscribe('messages:list', pageArgs);
      await settle();
      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: queryId,
              value: const <String, dynamic>{
                'page': <String>['stale'],
                'continueCursor': 'C',
                'isDone': false,
              },
            ),
          ],
        ).toJson(),
      );
      await settle();
      warmSubscription.cancel();
      await settle();

      final mutationFuture = client.mutate(
        'messages:refresh',
        const <String, dynamic>{},
        (store) => store.clearQuery('messages:list', pageArgs),
      );
      unawaited(mutationFuture.catchError((_) {}));
      await settle();

      final query = client.paginatedQuery(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
        pageSize: 2,
      );

      expect(query.current.results, isEmpty);
      expect(query.status, ConvexPaginationStatus.loadingFirstPage);

      query.cancel();
      client.dispose();
    });

    test('paginatedQuery reacts when a loaded page becomes optimistic loading',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://example.com',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final query = client.paginatedQuery(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
        pageSize: 2,
      );
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: queryId,
              value: const <String, dynamic>{
                'page': <String>['stale'],
                'continueCursor': 'C',
                'isDone': false,
              },
            ),
          ],
        ).toJson(),
      );
      await settle();
      expect(query.current.results, <dynamic>['stale']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);

      final pageArgs = <String, dynamic>{
        'channel': 'general',
        'paginationOpts': <String, dynamic>{
          'numItems': 2,
          'cursor': null,
        },
      };
      final mutationFuture = client.mutate(
        'messages:refresh',
        const <String, dynamic>{},
        (store) => store.clearQuery('messages:list', pageArgs),
      );
      unawaited(mutationFuture.catchError((_) {}));
      await settle();

      expect(query.current.results, isEmpty);
      expect(query.status, ConvexPaginationStatus.loadingFirstPage);

      query.cancel();
      client.dispose();
    });

    test('mutate overlays an optimistic update and rolls back on failure',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final subscription = client.subscribe('messages:list');
      final received = <Object?>[];
      subscription.stream.listen((event) {
        if (event is QuerySuccess) {
          received.add(event.value);
        } else if (event is QueryError) {
          received.add('error:${event.message}');
        }
      });
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;

      // Seed the server value ['a'].
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: const <String>['a']),
          ],
        ).toJson(),
      );
      await settle();
      expect(received.last, const <String>['a']);

      // Send a mutation with an optimistic update appending 'b'.
      final future = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
        (store) {
          final list = (store.getQuery('messages:list') as List<dynamic>?) ??
              const <dynamic>[];
          store.setQuery('messages:list', const <String, dynamic>{}, <dynamic>[
            ...list,
            'b',
          ]);
        },
      );
      final expectation = expectLater(future, throwsA(isA<ConvexException>()));
      // The optimistic value is shown to the subscriber synchronously.
      expect(received.last, const <String>['a', 'b']);
      await settle();

      // The server rejects the mutation; the overlay rolls back to ['a'].
      final mutation = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .last;
      adapter.pushServerMessage(
        MutationResponse(
          requestId: mutation['requestId'] as int,
          success: false,
          errorMessage: 'rejected',
        ).toJson(),
      );
      await settle();
      expect(received.last, const <String>['a']);
      await expectation;

      subscription.cancel();
      client.dispose();
    });

    test('optimistic clear emits loading to subscribers', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://example.com',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final subscription =
          client.subscribe('messages:list', const <String, dynamic>{});
      final received = <QueryResult>[];
      final streamSubscription = subscription.stream.listen(received.add);
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: const <String>['server']),
          ],
        ).toJson(),
      );
      await settle();
      expect(received.last, isA<QuerySuccess>());

      final future = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'pending'},
        (store) => store.clearQuery(
          'messages:list',
          const <String, dynamic>{},
        ),
      );
      await settle();

      expect(received.last, isA<QueryLoading>());
      expect((received.last as QueryLoading).hasPendingWrites, isTrue);

      final mutation = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .last;
      adapter.pushServerMessage(
        MutationResponse(
          requestId: mutation['requestId'] as int,
          success: false,
          errorMessage: 'rollback',
        ).toJson(),
      );
      await expectLater(future, throwsA(isA<ConvexException>()));

      await streamSubscription.cancel();
      subscription.cancel();
      client.dispose();
    });

    test('one-shot query ignores optimistic loading and waits for success',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://example.com',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final mutationFuture = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'pending'},
        (store) => store.clearQuery(
          'messages:once',
          const <String, dynamic>{},
        ),
      );
      unawaited(mutationFuture.catchError((_) {}));
      await settle();

      var completed = false;
      final queryFuture = client.query('messages:once').then((value) {
        completed = true;
        return value;
      });
      await settle();
      expect(completed, isFalse);

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: 'ready'),
          ],
        ).toJson(),
      );
      await settle();
      expect(completed, isFalse);

      final mutation = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .last;
      adapter.pushServerMessage(
        MutationResponse(
          requestId: mutation['requestId'] as int,
          success: false,
          errorMessage: 'rollback',
        ).toJson(),
      );
      await expectLater(queryFuture, completion('ready'));

      client.dispose();
    });

    test('cached subscription result waits for listener attachment', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final firstSubscription = client.subscribe('messages:list');
      final firstFuture = firstSubscription.stream.first;
      await settle();
      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: 'cached'),
          ],
        ).toJson(),
      );
      expect(await firstFuture, isA<QuerySuccess>());
      firstSubscription.cancel();
      await settle();

      final cachedSubscription = client.subscribe('messages:list');
      await Future<void>.delayed(Duration.zero);

      final cachedResult = await cachedSubscription.stream.first.timeout(
        const Duration(seconds: 1),
      );
      expect(
        cachedResult,
        isA<QuerySuccess>().having((result) => result.value, 'value', 'cached'),
      );

      cachedSubscription.cancel();
      client.dispose();
    });

    test('subscription re-listen seeds the latest query result', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'http://localhost:3210',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final subscription = client.subscribe('messages:list');
      final firstFuture = subscription.stream.first;
      await settle();
      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: 'current'),
          ],
        ).toJson(),
      );

      expect(
        await firstFuture,
        isA<QuerySuccess>()
            .having((result) => result.value, 'value', 'current'),
      );

      final secondResult = await subscription.stream.first.timeout(
        const Duration(seconds: 1),
      );
      expect(
        secondResult,
        isA<QuerySuccess>()
            .having((result) => result.value, 'value', 'current'),
      );

      subscription.cancel();
      client.dispose();
    });

    test('subscribe receives query errors with data and log lines', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final subscription = client.subscribe('messages:list');
      final future = subscription.stream.first;
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryFailed(
              queryId: queryId,
              errorMessage: 'not found',
              errorData: const <String, dynamic>{'code': 'missing'},
              logLines: const <String>['server log'],
            ),
          ],
        ).toJson(),
      );

      await expectLater(
        future,
        completion(
          isA<QueryError>()
              .having((error) => error.message, 'message', 'not found')
              .having(
            (error) => error.data,
            'data',
            const <String, dynamic>{'code': 'missing'},
          ).having(
            (error) => error.logLines,
            'logLines',
            const <String>['server log'],
          ),
        ),
      );
      client.dispose();
    });

    test('QueryError positional constructor remains source-compatible', () {
      const error = QueryError('message');

      expect(error.message, 'message');
      expect(error.data, isNull);
      expect(error.logLines, isEmpty);
    });

    test('query timeout cancels one-shot subscription', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          queryTimeout: const Duration(milliseconds: 1),
        ),
      );
      await settle();

      await expectLater(
        client.query('messages:list', const <String, dynamic>{}),
        throwsA(isA<TimeoutException>()),
      );
      await settle();

      final removeMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .where((message) {
        final modifications = message['modifications'] as List<dynamic>;
        return (modifications.single as Map<String, dynamic>)['type'] ==
            'Remove';
      }).toList(growable: false);
      expect(removeMessages, hasLength(1));

      client.dispose();
    });

    test('close fails a pending one-shot query', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final future = client.query('messages:list');
      final expectation = expectLater(
        future.timeout(const Duration(milliseconds: 50)),
        throwsA(
          isA<ConvexException>().having(
            (error) => error.message,
            'message',
            'ConvexClient has been disposed',
          ),
        ),
      );

      await client.close();

      await expectation;
    });

    test('mutation timeout completes caller future', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          mutationTimeout: const Duration(milliseconds: 1),
        ),
      );
      await settle();

      await expectLater(
        client.mutate(
          'messages:send',
          const <String, dynamic>{'body': 'hello'},
        ),
        throwsA(isA<TimeoutException>()),
      );
      adapter.disconnect(reason: 'timeout test reconnect');
      await settle();

      final mutationMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .toList(growable: false);
      expect(mutationMessages, hasLength(1));

      client.dispose();
    });

    test('action timeout completes caller future', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
          actionTimeout: const Duration(milliseconds: 1),
        ),
      );
      await settle();

      await expectLater(
        client.action(
          'messages:notify',
          const <String, dynamic>{'body': 'hello'},
        ),
        throwsA(isA<TimeoutException>()),
      );
      adapter.disconnect(reason: 'timeout test reconnect');
      await settle();

      final actionMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Action')
          .toList(growable: false);
      expect(actionMessages, hasLength(1));

      client.dispose();
    });

    test('fatal error terminates the connection without reconnecting',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final states = <ConnectionState>[];
      final stateSubscription = client.connectionState.listen(states.add);
      await settle();
      expect(adapter.connectedUrls, hasLength(1));

      final mutationFuture = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'hello'},
      );
      final mutationExpectation = expectLater(
        mutationFuture,
        throwsA(
          isA<ConvexException>().having(
            (error) => error.message,
            'message',
            'deployment is broken',
          ),
        ),
      );
      await settle();

      adapter.pushServerMessage(
        const FatalError(error: 'deployment is broken').toJson(),
      );
      await mutationExpectation;
      // Allow any (incorrectly) scheduled zero-delay reconnect to fire.
      await settle();
      await settle();

      expect(client.currentConnectionState, ConnectionState.fatalError);
      expect(states.last, ConnectionState.fatalError);
      // No reconnect was attempted after the fatal error.
      expect(adapter.connectedUrls, hasLength(1));

      await stateSubscription.cancel();
      client.dispose();
    });

    test('close during fatal termination does not report invalid message',
        () async {
      final adapter = _GatedCloseWebSocketAdapter();
      final logs = <DartvexLogEvent>[];
      final client = ConvexClient(
        'http://localhost:3210',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          logLevel: DartvexLogLevel.error,
          logger: logs.add,
        ),
      );
      await settle();

      adapter.pushServerMessage(
        const FatalError(error: 'deployment is broken').toJson(),
      );
      await adapter.closeStarted;

      final closeFuture = client.close();
      await settle();
      adapter.releaseClose();
      await closeFuture;
      await settle();

      expect(
        logs.where(
            (event) => event.message == 'Failed to handle WebSocket message'),
        isEmpty,
      );
    });

    test('mutation waits for transition before resolving', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final future = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'hello'},
      );
      await settle();

      final mutation = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .single;
      final requestId = mutation['requestId'] as int;
      var completed = false;
      future.then((_) {
        completed = true;
      });

      adapter.pushServerMessage(
        MutationResponse(
          requestId: requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
        ).toJson(),
      );
      await settle();
      expect(completed, isFalse);

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ).toJson(),
      );
      expect(await future, <String, dynamic>{'ok': true});
      client.dispose();
    });

    test('mutation queued while disconnected sends after reconnect', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      adapter.disconnect();
      final future = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'hello'},
      );
      var completed = false;
      future.then((_) {
        completed = true;
      });
      await settle();

      final mutation = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .single;
      final requestId = mutation['requestId'] as int;
      adapter.pushServerMessage(
        MutationResponse(
          requestId: requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
        ).toJson(),
      );
      await settle();
      expect(completed, isFalse);

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ).toJson(),
      );

      expect(await future, <String, dynamic>{'ok': true});
      client.dispose();
    });

    test('connected listeners do not send requests before reconnect replay',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final futures = <Future<dynamic>>[];
      var listenerSent = false;
      final stateSubscription = client.connectionState.listen((state) {
        if (state == ConnectionState.connected && !listenerSent) {
          listenerSent = true;
          futures.add(
            client.mutate(
              'messages:fromListener',
              const <String, dynamic>{'body': 'after-replay'},
            ).catchError((_) {}),
          );
        }
      });

      adapter.disconnect();
      futures.add(
        client.mutate(
          'messages:queued',
          const <String, dynamic>{'body': 'before-replay'},
        ).catchError((_) {}),
      );
      await settle();

      final messages = adapter.decodedSentMessages;
      final reconnectIndex = messages.lastIndexWhere(
        (message) => message['type'] == 'Connect',
      );
      final reconnectMutations = messages
          .asMap()
          .entries
          .where(
            (entry) =>
                entry.key > reconnectIndex && entry.value['type'] == 'Mutation',
          )
          .map((entry) => entry.value['udfPath'])
          .toList(growable: false);

      expect(reconnectMutations, <String>[
        'messages:queued',
        'messages:fromListener',
      ]);

      await stateSubscription.cancel();
      client.dispose();
      await Future.wait(futures);
    });

    test('action resolves immediately on action response', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final future = client.action(
        'messages:notify',
        const <String, dynamic>{'body': 'hello'},
      );
      await settle();

      final action = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Action')
          .single;
      adapter.pushServerMessage(
        ActionResponse(
          requestId: action['requestId'] as int,
          success: true,
          result: 'ok',
        ).toJson(),
      );

      expect(await future, 'ok');
      client.dispose();
    });

    test('in-flight action fails on disconnect', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final future = client.action(
        'messages:notify',
        const <String, dynamic>{'body': 'hello'},
      );
      await settle();

      final expectation = expectLater(
        future,
        throwsA(
          isA<ConvexException>()
              .having((error) => error.retryable, 'retryable', isTrue)
              .having(
                (error) => error.message,
                'message',
                contains('Connection lost while action was in flight'),
              ),
        ),
      );
      adapter.disconnect();

      await expectation;
      client.dispose();
    });

    test('dispose fails a mutation queued while disconnected', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration(seconds: 1)],
        ),
      );
      await settle();

      adapter.disconnect();
      final future = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'hello'},
      );
      final expectation = expectLater(
        future,
        throwsA(
          isA<ConvexException>().having(
            (error) => error.message,
            'message',
            'ConvexClient has been disposed',
          ),
        ),
      );

      client.dispose();

      await expectation;
    });

    test('ping is handled by transport without protocol response', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();
      final sentBeforePing = adapter.decodedSentMessages.length;

      adapter.pushServerMessage(const Ping().toJson());
      await settle();

      expect(adapter.decodedSentMessages, hasLength(sentBeforePing));
      client.dispose();
    });

    test('auth error clears auth and emits false', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final states = <bool>[];
      final subscription = client.authState.listen(states.add);
      await client.setAuth('jwt-token');
      await settle();

      adapter.pushServerMessage(
        const AuthError(
          error: 'bad token',
          baseVersion: 0,
          authUpdateAttempted: true,
        ).toJson(),
      );
      await settle();

      final lastAuthMessage = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Authenticate')
          .last;
      expect(lastAuthMessage['tokenType'], 'None');
      expect(states.last, isFalse);

      await subscription.cancel();
      client.dispose();
    });

    test('authRefreshing toggles true during reauth and false once confirmed',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final refreshing = <bool>[];
      final subscription = client.authRefreshing.listen(refreshing.add);

      var fetchCount = 0;
      await client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          fetchCount += 1;
          return 'token-$fetchCount';
        },
      );
      await settle();
      expect(client.isAuthRefreshing, isFalse);

      // The server rejects the token, triggering a reauth (stop, refetch,
      // restart) that surfaces as refreshing.
      adapter.pushServerMessage(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ).toJson(),
      );
      await settle();
      expect(client.isAuthRefreshing, isTrue);
      expect(refreshing, contains(true));

      // An identity-advancing transition confirms the fresh token.
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 1, ts: encodeTs(1)),
          modifications: const <StateModification>[],
        ).toJson(),
      );
      await settle();
      expect(client.isAuthRefreshing, isFalse);
      expect(refreshing.last, isFalse);

      await subscription.cancel();
      client.dispose();
    });

    test('reconnect auth confirmation does not re-emit auth state', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://example.com',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final states = <bool>[];
      final subscription = client.authState.listen(states.add);
      await client.setAuth('fixed-token');
      await settle();
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 1, ts: encodeTs(1)),
          modifications: const <StateModification>[],
        ).toJson(),
      );
      await settle();
      expect(states, <bool>[true]);

      states.clear();
      adapter.disconnect(reason: 'network drop');
      await waitForStatus(
        client,
        (status) => status.state == ConnectionState.connected,
      );
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 1, ts: encodeTs(2)),
          modifications: const <StateModification>[],
        ).toJson(),
      );
      await settle();

      expect(states, isEmpty);
      await subscription.cancel();
      client.dispose();
    });

    test('reconnect replays the cached token without re-fetching', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://example.com',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      var forcedRefreshCalls = 0;
      await client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (forceRefresh) {
            forcedRefreshCalls += 1;
            throw StateError('the provider must not be called on reconnect');
          }
          return 'cached-token';
        },
      );
      await settle();

      final sentMessageCountBeforeDisconnect =
          adapter.decodedSentMessages.length;
      adapter.disconnect(reason: 'network drop');
      await settle();

      await waitForStatus(
        client,
        (status) => status.state == ConnectionState.connected,
      );
      final authMessages = adapter.decodedSentMessages
          .skip(sentMessageCountBeforeDisconnect)
          .where((message) => message['type'] == 'Authenticate')
          .toList(growable: false);

      // Official parity: a reconnect replays the cached token from local state
      // and never calls the fetcher, so a failing forceRefresh provider can
      // neither break the handshake nor de-authenticate the client.
      expect(forcedRefreshCalls, 0);
      expect(authMessages, hasLength(1));
      expect(authMessages.single['value'], 'cached-token');

      client.dispose();
    });

    test('stale auth error is ignored after newer auth update', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      await client.setAuth('first-token');
      await client.setAuth('second-token');
      await settle();

      adapter.pushServerMessage(
        const AuthError(
          error: 'stale token',
          baseVersion: 0,
          authUpdateAttempted: true,
        ).toJson(),
      );
      await settle();

      final authMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Authenticate')
          .toList(growable: false);
      expect(authMessages.last['value'], 'second-token');
      expect(authMessages.last['tokenType'], 'User');

      client.dispose();
    });

    test('connection state emits reconnecting during reconnect attempts',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final states = <ConnectionState>[];
      final subscription = client.connectionState.listen(states.add);

      adapter.disconnect();
      await settle();

      expect(client.currentConnectionState, ConnectionState.connected);
      expect(states, contains(ConnectionState.disconnected));
      expect(states, contains(ConnectionState.reconnecting));
      expect(states.last, ConnectionState.connected);

      await subscription.cancel();
      client.dispose();
    });

    test('multiple identical subscriptions use one server query', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final first = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      final second = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      await settle();

      final modifyMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .toList();
      expect(modifyMessages, hasLength(1));

      first.cancel();
      second.cancel();
      client.dispose();
    });

    test('unsubscribe prevents data in flight from reaching listeners',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final events = <QueryResult>[];
      final subscription = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      final streamSubscription = subscription.stream.listen(events.add);
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .single;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;

      subscription.cancel();
      await settle();
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: 'late-data'),
          ],
        ).toJson(),
      );
      await settle();

      expect(events, isEmpty);
      await streamSubscription.cancel();
      client.dispose();
    });

    test('disconnect reconnects and rebuilds subscriptions', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final subscription = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      final future = subscription.stream.first;
      await settle();
      adapter.disconnect();
      await waitForStatus(
        client,
        (status) =>
            status.state == ConnectionState.connected &&
            status.connectionCount >= 2,
      );

      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList();
      expect(connectMessages.length, greaterThanOrEqualTo(2));

      final latestQuerySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((latestQuerySet['modifications'] as List<dynamic>)
          .single as Map<String, dynamic>)['queryId']) as int;
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: 'reconnected'),
          ],
        ).toJson(),
      );

      expect(await future, isA<QuerySuccess>());
      client.dispose();
    });

    test('transition chunks are reassembled before processing', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final subscription = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      final future = subscription.stream.first;
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).single
          as Map<String, dynamic>)['queryId']) as int;
      final transition = Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
        modifications: <StateModification>[
          QueryUpdated(queryId: queryId, value: 'chunked'),
        ],
      );
      final raw = jsonEncode(transition.toJson());
      final midpoint = raw.length ~/ 2;
      adapter.pushServerMessage(
        TransitionChunk(
          chunk: raw.substring(0, midpoint),
          partNumber: 0,
          totalParts: 2,
          transitionId: 'transition-1',
        ).toJson(),
      );
      adapter.pushServerMessage(
        TransitionChunk(
          chunk: raw.substring(midpoint),
          partNumber: 1,
          totalParts: 2,
          transitionId: 'transition-1',
        ).toJson(),
      );

      expect(await future, isA<QuerySuccess>());
      client.dispose();
    });

    test('reconnects immediately when connectivity is restored', () async {
      final adapter = MockWebSocketAdapter();
      final signal = _FakeConnectivitySignal();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          connectivitySignal: signal,
          reconnectBackoff: const <Duration>[Duration(hours: 1)],
        ),
      );

      final subscription = client.subscribe('messages:list');
      await settle();
      expect(adapter.connectedUrls, hasLength(1));

      adapter.disconnect();
      await settle();

      signal.restore();
      await settle();
      expect(adapter.connectedUrls, hasLength(2));

      subscription.cancel();
      client.dispose();
      signal.dispose();
    });

    group('connection status', () {
      test('fromState derives a coarse-only snapshot', () {
        final connected = ConnectionStatus.fromState(ConnectionState.connected);
        expect(connected.isConnected, isTrue);
        expect(connected.isWebSocketConnected, isTrue);
        expect(connected.hasEverConnected, isTrue);
        expect(connected.isLoading, isFalse);

        final reconnecting =
            ConnectionStatus.fromState(ConnectionState.reconnecting);
        expect(reconnecting.isConnected, isFalse);
        expect(reconnecting.hasEverConnected, isTrue);
        expect(reconnecting.isLoading, isTrue);

        final disconnected =
            ConnectionStatus.fromState(ConnectionState.disconnected);
        expect(disconnected.hasEverConnected, isFalse);
        expect(disconnected.isConnected, isFalse);
      });

      test('starts disconnected with nothing in flight', () {
        final adapter = MockWebSocketAdapter();
        final client = ConvexClient(
          'https://demo.convex.cloud',
          config: ConvexClientConfig(
            adapterFactory: (_) => adapter,
            connectImmediately: false,
            reconnectBackoff: const <Duration>[Duration.zero],
          ),
        );

        final status = client.currentConnectionStatus;
        expect(status.state, ConnectionState.disconnected);
        expect(status.isWebSocketConnected, isFalse);
        expect(status.isConnected, isFalse);
        expect(status.hasEverConnected, isFalse);
        expect(status.connectionCount, 0);
        expect(status.inflightMutations, 0);
        expect(status.inflightActions, 0);
        expect(status.hasInflightRequests, isFalse);
        expect(status.timeOfOldestInflightRequest, isNull);

        client.dispose();
      });

      test('is loading after connect until the first sync, then connected',
          () async {
        final adapter = MockWebSocketAdapter();
        final client = ConvexClient(
          'https://demo.convex.cloud',
          config: ConvexClientConfig(
            adapterFactory: (_) => adapter,
            reconnectBackoff: const <Duration>[Duration.zero],
          ),
        );

        final subscription = client.subscribe('messages:list');
        subscription.stream.listen((_) {});
        await settle();

        var status = client.currentConnectionStatus;
        expect(status.isWebSocketConnected, isTrue);
        expect(status.hasEverConnected, isTrue);
        expect(status.state, ConnectionState.connected);
        expect(status.hasSyncedPastLastReconnect, isFalse);
        expect(status.isLoading, isTrue);
        expect(status.isConnected, isFalse);

        final querySet = adapter.decodedSentMessages
            .where((message) => message['type'] == 'ModifyQuerySet')
            .last;
        final queryId = (((querySet['modifications'] as List<dynamic>).single
            as Map<String, dynamic>)['queryId']) as int;
        adapter.pushServerMessage(
          Transition(
            startVersion: const StateVersion.initial(),
            endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
            modifications: <StateModification>[
              QueryUpdated(queryId: queryId, value: const <String>['a']),
            ],
          ).toJson(),
        );
        await settle();

        status = client.currentConnectionStatus;
        expect(status.hasSyncedPastLastReconnect, isTrue);
        expect(status.isLoading, isFalse);
        expect(status.isConnected, isTrue);

        subscription.cancel();
        client.dispose();
      });

      test('reports inflight mutations and actions and emits on change',
          () async {
        final adapter = MockWebSocketAdapter();
        final client = ConvexClient(
          'https://demo.convex.cloud',
          config: ConvexClientConfig(
            adapterFactory: (_) => adapter,
            reconnectBackoff: const <Duration>[Duration.zero],
          ),
        );
        final statuses = <ConnectionStatus>[];
        final statusSub = client.connectionStatus.listen(statuses.add);
        await settle();

        final mutationFuture = client.mutate(
          'messages:send',
          const <String, dynamic>{'body': 'x'},
        );
        final actionFuture = client.action(
          'messages:notify',
          const <String, dynamic>{'to': 'y'},
        );
        await settle();

        var status = client.currentConnectionStatus;
        expect(status.inflightMutations, 1);
        expect(status.inflightActions, 1);
        expect(status.hasInflightRequests, isTrue);
        expect(status.timeOfOldestInflightRequest, isNotNull);
        expect(
          statuses.any(
            (s) => s.inflightMutations == 1 && s.inflightActions == 1,
          ),
          isTrue,
        );

        final mutation = adapter.decodedSentMessages
            .where((message) => message['type'] == 'Mutation')
            .last;
        final action = adapter.decodedSentMessages
            .where((message) => message['type'] == 'Action')
            .last;
        adapter.pushServerMessage(
          MutationResponse(
            requestId: mutation['requestId'] as int,
            success: true,
            result: 'ok',
            ts: encodeTs(4),
          ).toJson(),
        );
        adapter.pushServerMessage(
          Transition(
            startVersion: const StateVersion.initial(),
            endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
            modifications: const <StateModification>[],
          ).toJson(),
        );
        adapter.pushServerMessage(
          ActionResponse(
            requestId: action['requestId'] as int,
            success: true,
            result: 'done',
          ).toJson(),
        );
        await settle();

        expect(await mutationFuture, 'ok');
        expect(await actionFuture, 'done');
        status = client.currentConnectionStatus;
        expect(status.inflightMutations, 0);
        expect(status.inflightActions, 0);
        expect(status.hasInflightRequests, isFalse);
        expect(status.timeOfOldestInflightRequest, isNull);
        expect(statuses.last.hasInflightRequests, isFalse);

        await statusSub.cancel();
        client.dispose();
      });

      test('connectionCount and connectionRetries climb while flapping',
          () async {
        final adapter = MockWebSocketAdapter();
        final client = ConvexClient(
          'https://demo.convex.cloud',
          config: ConvexClientConfig(
            adapterFactory: (_) => adapter,
            reconnectBackoff: const <Duration>[],
            initialBackoff: Duration.zero,
            backoffJitter: 0,
          ),
        );
        await settle();
        expect(client.currentConnectionStatus.hasEverConnected, isTrue);
        expect(client.currentConnectionStatus.connectionCount, 1);

        adapter.disconnect();
        await waitForStatus(
          client,
          (status) =>
              status.connectionCount >= 2 && status.isWebSocketConnected,
        );
        adapter.disconnect();
        await waitForStatus(
          client,
          (status) =>
              status.connectionCount >= 3 && status.isWebSocketConnected,
        );

        final status = client.currentConnectionStatus;
        expect(status.connectionCount, 3);
        expect(status.connectionRetries, 2);
        expect(status.hasEverConnected, isTrue);

        client.dispose();
      });
    });
  });
}

class _FakeConnectivitySignal implements ConnectivitySignal {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  @override
  Stream<void> get onRestored => _controller.stream;

  void restore() => _controller.add(null);

  void dispose() => _controller.close();
}

final class _GatedCloseWebSocketAdapter extends MockWebSocketAdapter {
  final Completer<void> _closeStarted = Completer<void>();
  final Completer<void> _releaseClose = Completer<void>();

  Future<void> get closeStarted => _closeStarted.future;

  void releaseClose() {
    if (!_releaseClose.isCompleted) {
      _releaseClose.complete();
    }
  }

  @override
  Future<void> close() async {
    if (!_closeStarted.isCompleted) {
      _closeStarted.complete();
    }
    await _releaseClose.future;
    await super.close();
  }
}
