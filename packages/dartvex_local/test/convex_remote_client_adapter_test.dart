import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart' as convex;
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/transport/ws_interface.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:test/test.dart';

void main() {
  group('ConvexRemoteClientAdapter', () {
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    test('seeds currentConnectionState from wrapped client', () async {
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: const convex.ConvexClientConfig(connectImmediately: false),
      );
      final adapter = ConvexRemoteClientAdapter(client);

      expect(
        adapter.currentConnectionState,
        LocalRemoteConnectionState.disconnected,
      );

      adapter.dispose();
      client.dispose();
    });

    test(
      'clearAuth then reset cannot repopulate SQLite with the previous user',
      () async {
        final socket = _MockWebSocketAdapter();
        final core = convex.ConvexClient(
          'https://demo.convex.cloud',
          config: convex.ConvexClientConfig(adapterFactory: (_) => socket),
        );
        final store = await SqliteLocalStore.openInMemory();
        final local = await ConvexLocalClient.open(
          client: core,
          config: LocalClientConfig(cacheStorage: store, queueStorage: store),
        );
        addTearDown(() async {
          await local.dispose();
          await core.close();
        });
        await settle();
        await core.setAuth('alice-token');
        final subscription = local.subscribe('profile:me');
        final events = <LocalQueryEvent>[];
        final listener = subscription.stream.listen(events.add);
        addTearDown(listener.cancel);
        await settle();
        final querySet = socket.decodedSentMessages
            .where((m) => m['type'] == 'ModifyQuerySet')
            .last;
        final id = (querySet['modifications'] as List).first['queryId'] as int;
        final version = StateVersion(
          querySet: querySet['newVersion'] as int,
          identity: 1,
          ts: encodeTs(1),
        );
        socket.pushServerMessage(
          Transition(
            startVersion: const StateVersion.initial(),
            endVersion: version,
            modifications: [
              QueryUpdated(queryId: id, value: 'alice private data'),
            ],
          ).toJson(),
        );
        await settle();
        expect(
          events.whereType<LocalQuerySuccess>().last.value,
          'alice private data',
        );

        await core.clearAuth();
        await local.reset();
        events.clear();
        var completed = false;
        final query = local.query('profile:me').then((value) {
          completed = true;
          return value;
        });
        await settle();
        expect(completed, isFalse);
        expect(events.whereType<LocalQuerySuccess>(), isEmpty);
        await local.setNetworkMode(LocalNetworkMode.offline);
        await expectLater(local.query('profile:me'), throwsStateError);
        await local.setNetworkMode(LocalNetworkMode.auto);

        final newQuerySet = socket.decodedSentMessages
            .where((m) => m['type'] == 'ModifyQuerySet')
            .last;
        socket.pushServerMessage(
          Transition(
            startVersion: version,
            endVersion: StateVersion(
              querySet: newQuerySet['newVersion'] as int,
              identity: 2,
              ts: encodeTs(2),
            ),
            modifications: [QueryUpdated(queryId: id, value: 'public data')],
          ).toJson(),
        );
        expect(await query, 'public data');
        await local.setNetworkMode(LocalNetworkMode.offline);
        expect(await local.query('profile:me'), 'public data');
      },
    );

    test('preserves remote query error data and log lines', () async {
      final socket = _MockWebSocketAdapter();
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: convex.ConvexClientConfig(
          adapterFactory: (_) => socket,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final adapter = ConvexRemoteClientAdapter(client, disposeClient: true);
      await settle();

      final subscription = adapter.subscribe('messages:list');
      final future = subscription.stream.first;
      await settle();

      final querySet = socket.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId =
          (((querySet['modifications'] as List<dynamic>).single
                  as Map<String, dynamic>)['queryId'])
              as int;

      socket.pushServerMessage(
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
          isA<LocalRemoteQueryError>().having(
            (event) => event.error,
            'error',
            isA<convex.ConvexException>()
                .having((error) => error.message, 'message', 'not found')
                .having((error) => error.data, 'data', const <String, dynamic>{
                  'code': 'missing',
                })
                .having((error) => error.logLines, 'logLines', const <String>[
                  'server log',
                ]),
          ),
        ),
      );

      subscription.cancel();
      adapter.dispose();
    });

    test('maps remote optimistic loading events', () async {
      final socket = _MockWebSocketAdapter();
      final client = convex.ConvexClient(
        'https://example.com',
        config: convex.ConvexClientConfig(
          adapterFactory: (_) => socket,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final adapter = ConvexRemoteClientAdapter(client, disposeClient: true);
      await settle();

      final subscription = adapter.subscribe('messages:list');
      final events = <LocalRemoteQueryEvent>[];
      final listener = subscription.stream.listen(events.add);
      await settle();

      final mutationFuture = client.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'pending'},
        (store) => store.clearQuery('messages:list', const <String, dynamic>{}),
      );
      unawaited(mutationFuture.catchError((_) {}));
      await settle();

      expect(
        events,
        contains(
          isA<LocalRemoteQueryLoading>().having(
            (event) => event.hasPendingWrites,
            'hasPendingWrites',
            isTrue,
          ),
        ),
      );

      await listener.cancel();
      subscription.cancel();
      adapter.dispose();
    });

    test(
      'tags the core after-unsubscribe seed and not server results',
      () async {
        final socket = _MockWebSocketAdapter();
        final client = convex.ConvexClient(
          'https://demo.convex.cloud',
          config: convex.ConvexClientConfig(
            adapterFactory: (_) => socket,
            reconnectBackoff: const <Duration>[Duration.zero],
          ),
        );
        final adapter = ConvexRemoteClientAdapter(client, disposeClient: true);
        addTearDown(adapter.dispose);
        await settle();

        var version = 0;
        void pushValue(int queryId, Object value) {
          socket.pushServerMessage(
            Transition(
              startVersion: StateVersion(
                querySet: version,
                identity: 0,
                ts: encodeTs(version),
              ),
              endVersion: StateVersion(
                querySet: version + 1,
                identity: 0,
                ts: encodeTs(version + 1),
              ),
              modifications: <StateModification>[
                QueryUpdated(
                  queryId: queryId,
                  value: value,
                  logLines: const [],
                ),
              ],
            ).toJson(),
          );
          version += 1;
        }

        int lastAddedQueryId() {
          final querySet = socket.decodedSentMessages
              .where((message) => message['type'] == 'ModifyQuerySet')
              .last;
          final add =
              (querySet['modifications'] as List<dynamic>).last
                  as Map<String, dynamic>;
          return add['queryId'] as int;
        }

        final first = adapter.subscribe('messages:list');
        final firstEvents = <LocalRemoteQueryEvent>[];
        final firstListener = first.stream.listen(firstEvents.add);
        await settle();
        pushValue(lastAddedQueryId(), <dynamic>['old']);
        await settle();
        expect(
          firstEvents.whereType<LocalRemoteQuerySuccess>().single.isSeed,
          isFalse,
        );
        await firstListener.cancel();
        first.cancel();
        await settle();

        // Resubscribing: the core seeds the listener from its after-unsubscribe
        // cache before the server answers the new subscription.
        final second = adapter.subscribe('messages:list');
        final secondEvents = <LocalRemoteQuerySuccess>[];
        final secondListener = second.stream
            .where((event) => event is LocalRemoteQuerySuccess)
            .cast<LocalRemoteQuerySuccess>()
            .listen(secondEvents.add);
        await settle();
        expect(secondEvents, hasLength(1));
        expect(secondEvents.single.value, <dynamic>['old']);
        expect(secondEvents.single.isSeed, isTrue);

        pushValue(lastAddedQueryId(), <dynamic>['new']);
        await settle();
        expect(secondEvents, hasLength(2));
        expect(secondEvents.last.value, <dynamic>['new']);
        expect(secondEvents.last.isSeed, isFalse);

        await secondListener.cancel();
        second.cancel();
      },
    );

    test('reports disconnected once the wrapped client is closed', () async {
      final socket = _MockWebSocketAdapter();
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: convex.ConvexClientConfig(
          adapterFactory: (_) => socket,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final adapter = ConvexRemoteClientAdapter(client);
      addTearDown(adapter.dispose);
      await settle();
      expect(
        adapter.currentConnectionState,
        LocalRemoteConnectionState.connected,
      );

      final states = <LocalRemoteConnectionState>[];
      final listener = adapter.connectionState.listen(states.add);
      addTearDown(listener.cancel);

      final inFlight = adapter.mutate('messages:send');
      await settle();
      final close = client.close();

      // The in-flight failure must already see the remote as disconnected,
      // before the core finishes closing its streams.
      Object? observedError;
      LocalRemoteConnectionState? stateAtFailure;
      try {
        await inFlight;
      } catch (error) {
        observedError = error;
        stateAtFailure = adapter.currentConnectionState;
      }
      expect(observedError, isA<convex.ConvexException>());
      expect(isClosedClientError(observedError!), isTrue);
      expect(stateAtFailure, LocalRemoteConnectionState.disconnected);
      expect(states, contains(LocalRemoteConnectionState.disconnected));

      await close;
      await expectLater(
        adapter.mutate('messages:send'),
        throwsA(isA<convex.ConvexException>()),
      );
      expect(
        adapter.currentConnectionState,
        LocalRemoteConnectionState.disconnected,
      );
    });
  });
}

bool isClosedClientError(Object error) =>
    error is convex.ConvexException &&
    !error.retryable &&
    error.message.contains('disposed');

class _MockWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast();

  final List<String> sentMessages = <String>[];
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    _connected = true;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Mock socket is disconnected');
    }
    sentMessages.add(message);
  }

  List<Map<String, dynamic>> get decodedSentMessages {
    return sentMessages
        .map((message) => jsonDecode(message) as Map<String, dynamic>)
        .toList(growable: false);
  }

  void pushServerMessage(Map<String, dynamic> message) {
    _messagesController.add(jsonEncode(message));
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeController.stream;

  @override
  Future<void> close() async {
    _connected = false;
    _closeController.add(const WebSocketCloseEvent());
  }

  @override
  bool get isConnected => _connected;
}
