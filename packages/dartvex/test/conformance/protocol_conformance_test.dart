@Tags(['conformance'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import '../test_helpers/mock_web_socket_adapter.dart';

/// Wire-level conformance for the Convex sync protocol, driving a real
/// [ConvexClient] over a scriptable in-memory socket ([MockWebSocketAdapter]).
///
/// This runs in CI without a backend; the live counterpart that exercises the
/// same flows against a real deployment lives in
/// `live_backend_conformance_test.dart` and is skipped unless
/// `CONVEX_DEPLOYMENT_URL` is set.
void main() {
  group('protocol conformance (fake transport)', () {
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 10));

    ConvexClient connectedClient(MockWebSocketAdapter adapter) => ConvexClient(
          'https://demo.convex.cloud',
          config: ConvexClientConfig(
            adapterFactory: (_) => adapter,
            reconnectBackoff: const <Duration>[Duration.zero],
          ),
        );

    List<Map<String, dynamic>> sentOfType(
      MockWebSocketAdapter adapter,
      String type,
    ) =>
        adapter.decodedSentMessages
            .where((message) => message['type'] == type)
            .toList(growable: false);

    List<Map<String, dynamic>> modificationsOfType(
      MockWebSocketAdapter adapter,
      String type,
    ) =>
        sentOfType(adapter, 'ModifyQuerySet')
            .expand(
              (message) => (message['modifications'] as List<dynamic>)
                  .cast<Map<String, dynamic>>(),
            )
            .where((modification) => modification['type'] == type)
            .toList(growable: false);

    int firstAddedQueryId(MockWebSocketAdapter adapter) =>
        modificationsOfType(adapter, 'Add').first['queryId'] as int;

    test('opens with a Connect handshake carrying session and clientTs',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = connectedClient(adapter);
      await settle();

      final connects = sentOfType(adapter, 'Connect');
      expect(connects, isNotEmpty);
      final connect = connects.first;
      expect(connect['sessionId'], isA<String>());
      expect((connect['sessionId'] as String).isNotEmpty, isTrue);
      expect(connect['connectionCount'], 0);
      expect(connect['clientTs'], isA<int>());
      expect(connect['clientTs'] as int, greaterThan(0));

      client.dispose();
    });

    test('subscribe emits a ModifyQuerySet Add; unsubscribe emits a Remove',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = connectedClient(adapter);
      final subscription = client.subscribe(
        'messages:list',
        const <String, dynamic>{'room': 'general'},
      );
      subscription.stream.listen((_) {});
      await settle();

      final adds = modificationsOfType(adapter, 'Add');
      expect(adds, isNotEmpty);
      expect(adds.first['udfPath'], 'messages:list');
      expect(adds.first['queryId'], isA<int>());
      final queryId = adds.first['queryId'] as int;

      subscription.cancel();
      await settle();
      expect(
        modificationsOfType(adapter, 'Remove')
            .any((modification) => modification['queryId'] == queryId),
        isTrue,
      );

      client.dispose();
    });

    test('setAuth sends an Authenticate message with the token', () async {
      final adapter = MockWebSocketAdapter();
      final client = connectedClient(adapter);
      await settle();

      await client.setAuth('jwt-token');
      await settle();

      final auths = sentOfType(adapter, 'Authenticate');
      expect(auths, isNotEmpty);
      expect(auths.last['value'], 'jwt-token');
      expect(auths.last['tokenType'], isA<String>());

      client.dispose();
    });

    test('mutate and action send Mutation and Action messages', () async {
      final adapter = MockWebSocketAdapter();
      final client = connectedClient(adapter);
      await settle();

      unawaited(
        client.mutate('messages:send', const <String, dynamic>{
          'body': 'hi'
        }).catchError((Object _) => null),
      );
      unawaited(
        client.action('messages:notify',
            const <String, dynamic>{'to': 'x'}).catchError((Object _) => null),
      );
      await settle();

      final mutations = sentOfType(adapter, 'Mutation');
      expect(mutations, isNotEmpty);
      expect(mutations.last['udfPath'], 'messages:send');
      expect(mutations.last['requestId'], isA<int>());

      final actions = sentOfType(adapter, 'Action');
      expect(actions, isNotEmpty);
      expect(actions.last['udfPath'], 'messages:notify');
      expect(actions.last['requestId'], isA<int>());

      client.dispose();
    });

    test('applies a Transition to the subscribed query', () async {
      final adapter = MockWebSocketAdapter();
      final client = connectedClient(adapter);
      final received = <dynamic>[];
      final subscription = client.subscribe('messages:list');
      subscription.stream.listen((event) {
        if (event is QuerySuccess) {
          received.add(event.value);
        }
      });
      await settle();
      final queryId = firstAddedQueryId(adapter);

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: const <String>['hello']),
          ],
        ).toJson(),
      );
      await settle();

      expect(received.last, const <String>['hello']);

      subscription.cancel();
      client.dispose();
    });

    test('reconnect replays the query set under a new Connect', () async {
      final adapter = MockWebSocketAdapter();
      final client = connectedClient(adapter);
      final subscription = client.subscribe('messages:list');
      subscription.stream.listen((_) {});
      await settle();
      final firstConnect = sentOfType(adapter, 'Connect').first;

      adapter.disconnect();
      await settle();

      final connects = sentOfType(adapter, 'Connect');
      expect(connects.length, greaterThanOrEqualTo(2));
      expect(connects.last['connectionCount'], 1);
      expect(connects.last['sessionId'], firstConnect['sessionId']);
      // The subscription is replayed after the reconnect handshake, so the Add
      // for it appears on both the initial and the post-reconnect query set.
      final replayedAdds = modificationsOfType(adapter, 'Add')
          .where((modification) => modification['udfPath'] == 'messages:list');
      expect(replayedAdds.length, greaterThanOrEqualTo(2));

      subscription.cancel();
      client.dispose();
    });

    test('assembles a chunked Transition and applies it', () async {
      final adapter = MockWebSocketAdapter();
      final client = connectedClient(adapter);
      final received = <dynamic>[];
      final subscription = client.subscribe('messages:list');
      subscription.stream.listen((event) {
        if (event is QuerySuccess) {
          received.add(event.value);
        }
      });
      await settle();
      final queryId = firstAddedQueryId(adapter);

      final encoded = jsonEncode(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: const <String>['chunked']),
          ],
        ).toJson(),
      );
      final mid = (encoded.length / 2).floor();
      adapter.pushServerMessage(
        TransitionChunk(
          transitionId: 'tx-1',
          partNumber: 0,
          totalParts: 2,
          chunk: encoded.substring(0, mid),
        ).toJson(),
      );
      adapter.pushServerMessage(
        TransitionChunk(
          transitionId: 'tx-1',
          partNumber: 1,
          totalParts: 2,
          chunk: encoded.substring(mid),
        ).toJson(),
      );
      await settle();

      expect(received.last, const <String>['chunked']);

      subscription.cancel();
      client.dispose();
    });
  });
}
