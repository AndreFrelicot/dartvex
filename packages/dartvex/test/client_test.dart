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

    test('ping triggers pong event', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      adapter.pushServerMessage(const Ping().toJson());
      await settle();

      expect(adapter.decodedSentMessages.last['eventType'], 'Pong');
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
      await settle();

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
          chunk: base64Encode(raw.substring(0, midpoint).codeUnits),
          partNumber: 1,
          totalParts: 2,
          transitionId: 'transition-1',
        ).toJson(),
      );
      adapter.pushServerMessage(
        TransitionChunk(
          chunk: base64Encode(raw.substring(midpoint).codeUnits),
          partNumber: 2,
          totalParts: 2,
          transitionId: 'transition-1',
        ).toJson(),
      );

      expect(await future, isA<QuerySuccess>());
      client.dispose();
    });
  });
}
