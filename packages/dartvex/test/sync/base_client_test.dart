import 'dart:async';

import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/sync/base_client.dart';
import 'package:test/test.dart';

void main() {
  group('BaseClient', () {
    test('subscribe emits query update event on transition', () {
      final client = BaseClient();
      final registration = client.subscribe('messages:list', <String, dynamic>{
        'channel': 'general',
      });
      client.drainOutgoing();

      final result = client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: registration.queryId,
              value: const <String, dynamic>{'body': 'hello'},
            ),
          ],
        ),
      );

      expect(result.events.single, isA<QueryUpdateEvent>());
    });

    test('mutation resolves only after qualifying transition', () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', <String, dynamic>{
        'body': 'hello',
      });
      final outgoing = client.drainOutgoing();
      final mutation = outgoing.single as Mutation;
      var completed = false;
      future.then((_) {
        completed = true;
      });

      client.receive(
        MutationResponse(
          requestId: mutation.requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ),
      );
      expect(await future, <String, dynamic>{'ok': true});
    });

    test('action resolves immediately', () async {
      final client = BaseClient();
      final future = client.action('messages:notify', <String, dynamic>{
        'body': 'hello',
      });
      final action = client.drainOutgoing().single as Action;

      client.receive(
        const ActionResponse(
          requestId: 0,
          success: true,
          result: 'ok',
        ),
      );

      expect(action.requestId, 0);
      expect(await future, 'ok');
    });

    test('ping queues pong event', () {
      final client = BaseClient();
      final result = client.receive(const Ping());
      expect(result.outgoing.single.toJson(), <String, dynamic>{
        'type': 'Event',
        'eventType': 'Pong',
        'event': null,
      });
    });

    test('auth error produces auth error event', () {
      final client = BaseClient();
      final result = client.receive(
        const AuthError(error: 'expired', baseVersion: 0),
      );
      expect(result.events.single, isA<AuthErrorEvent>());
    });

    test('same query deduplicates to one server subscription', () {
      final client = BaseClient();
      final first = client.subscribe('messages:list', const <String, dynamic>{
        'channel': 'general',
      });
      final second = client.subscribe('messages:list', const <String, dynamic>{
        'channel': 'general',
      });

      final outgoing = client.drainOutgoing();
      expect(outgoing, hasLength(1));
      expect(first.queryId, second.queryId);
      expect(client.subscriberIdsForQuery(first.queryId), hasLength(2));
    });

    test('prepare reconnect rebuilds subscriptions from version zero', () {
      final client = BaseClient();
      final registration = client.subscribe(
        'messages:list',
        const <String, dynamic>{'channel': 'general'},
      );
      client.drainOutgoing();

      client.handleDisconnect('socket closed');
      final reconnectMessages = client.prepareReconnect();
      final querySet = reconnectMessages.single as ModifyQuerySet;

      expect(querySet.baseVersion, 0);
      expect(querySet.newVersion, 1);
      expect(
          (querySet.modifications.single as Add).queryId, registration.queryId);
    });
  });
}
