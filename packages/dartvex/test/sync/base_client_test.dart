import 'dart:async';

import 'package:dartvex/src/exceptions.dart';
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

    test('mutation created while disconnected is sent on reconnect', () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', <String, dynamic>{
        'body': 'hello',
      });

      final reconnectMessages = client.prepareReconnect();
      final mutation = reconnectMessages.single as Mutation;

      client.receive(
        MutationResponse(
          requestId: mutation.requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
        ),
      );
      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ),
      );

      expect(await future, <String, dynamic>{'ok': true});
    });

    test('in-flight mutation is replayed after reconnect', () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', <String, dynamic>{
        'body': 'hello',
      });
      final mutation = client.drainOutgoing().single as Mutation;

      client.handleDisconnect('socket closed');
      final reconnectMessages = client.prepareReconnect();

      expect(reconnectMessages.single, isA<Mutation>());
      expect(
          (reconnectMessages.single as Mutation).requestId, mutation.requestId);

      client.receive(
        MutationResponse(
          requestId: mutation.requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
        ),
      );
      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ),
      );

      expect(await future, <String, dynamic>{'ok': true});
    });

    test('completed mutation is replayed until transition catches up',
        () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', <String, dynamic>{
        'body': 'hello',
      });
      final mutation = client.drainOutgoing().single as Mutation;
      var completions = 0;
      future.then((_) {
        completions += 1;
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
      expect(completions, 0);

      client.handleDisconnect('socket closed');
      final reconnectMessages = client.prepareReconnect();
      expect(
          (reconnectMessages.single as Mutation).requestId, mutation.requestId);

      client.receive(
        MutationResponse(
          requestId: mutation.requestId,
          success: true,
          result: const <String, dynamic>{'ok': 'duplicate'},
          ts: encodeTs(4),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completions, 0);

      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ),
      );

      expect(await future, <String, dynamic>{'ok': true});
      expect(completions, 1);
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

    test('in-flight action fails on disconnect', () async {
      final client = BaseClient();
      final future = client.action('messages:notify', <String, dynamic>{
        'body': 'hello',
      });
      client.drainOutgoing();
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

      client.handleDisconnect('socket closed');

      await expectation;
      expect(client.prepareReconnect(), isEmpty);
    });

    test('unsent action is sent on reconnect', () async {
      final client = BaseClient();
      final future = client.action('messages:notify', <String, dynamic>{
        'body': 'hello',
      });
      var completed = false;
      future.then(
        (_) {
          completed = true;
        },
        onError: (_) {
          completed = true;
        },
      );

      client.handleDisconnect('socket closed');
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      final reconnectMessages = client.prepareReconnect();
      final action = reconnectMessages.single as Action;
      client.receive(
        ActionResponse(
          requestId: action.requestId,
          success: true,
          result: 'ok',
        ),
      );

      expect(await future, 'ok');
    });

    test('reconnect preserves original replayable request order', () {
      final client = BaseClient();
      unawaited(client.action('messages:notify', <String, dynamic>{
        'body': 'hello',
      }));
      unawaited(client.mutate('messages:send', <String, dynamic>{
        'body': 'world',
      }));

      final reconnectMessages = client.prepareReconnect();

      expect(reconnectMessages, hasLength(2));
      expect(reconnectMessages.first, isA<Action>());
      expect(reconnectMessages.last, isA<Mutation>());
    });

    test('failPendingRequests completes queued requests with error', () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', <String, dynamic>{
        'body': 'hello',
      });
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

      client.failPendingRequests('ConvexClient has been disposed');

      await expectation;
      expect(client.prepareReconnect(), isEmpty);
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
