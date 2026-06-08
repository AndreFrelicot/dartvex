import 'dart:async';

import 'package:dartvex/src/exceptions.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/sync/base_client.dart';
import 'package:dartvex/src/sync/remote_query_set.dart';
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

    test('transition surfaces query function logs once, before the update', () {
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
              logLines: const <String>['first log', 'second log'],
            ),
          ],
        ),
      );

      final logs = result.events.whereType<QueryLogEvent>().toList();
      expect(logs.map((log) => log.line), <String>['first log', 'second log']);
      expect(logs.every((log) => log.name == 'messages:list'), isTrue);
      expect(
        logs.every((log) => log.queryId == registration.queryId),
        isTrue,
      );
      // Logs precede the value update, mirroring the official ordering.
      final lastLogIndex =
          result.events.lastIndexWhere((event) => event is QueryLogEvent);
      final firstUpdateIndex =
          result.events.indexWhere((event) => event is QueryUpdateEvent);
      expect(lastLogIndex, lessThan(firstUpdateIndex));
    });

    test('failed query still surfaces its function logs', () {
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
            QueryFailed(
              queryId: registration.queryId,
              errorMessage: 'boom',
              logLines: const <String>['ran before throwing'],
            ),
          ],
        ),
      );

      final logs = result.events.whereType<QueryLogEvent>().toList();
      expect(logs.single.line, 'ran before throwing');
      expect(logs.single.name, 'messages:list');
    });

    test('query logs are not re-emitted when an optimistic overlay replays',
        () {
      // A second, unrelated transition (no logs) must not resurface the logs
      // from the first: query logs come from the raw modifications, once per
      // transition, never from a cache/overlay re-emit.
      final client = BaseClient();
      final registration = client.subscribe('messages:list', <String, dynamic>{
        'channel': 'general',
      });
      client.drainOutgoing();

      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: registration.queryId,
              value: const <String, dynamic>{'body': 'hello'},
              logLines: const <String>['only once'],
            ),
          ],
        ),
      );

      final second = client.receive(
        Transition(
          startVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(2)),
          modifications: const <StateModification>[],
        ),
      );

      expect(second.events.whereType<QueryLogEvent>(), isEmpty);
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

    test(
        'replayed read-your-writes mutation does not re-log its function lines',
        () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', <String, dynamic>{
        'body': 'hello',
      });
      final mutation = client.drainOutgoing().single as Mutation;

      // The first response carries a future ts, so the mutation parks awaiting
      // its read-your-writes transition; its log lines are emitted once.
      final first = client.receive(
        MutationResponse(
          requestId: mutation.requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
          logLines: const <String>['mutation log'],
        ),
      );
      expect(
        first.events.whereType<FunctionLogEvent>().map((event) => event.line),
        <String>['mutation log'],
      );

      // A reconnect replays the still-parked mutation and the server re-sends
      // the same response. Its log lines must NOT be emitted again — the
      // official client skips already-completed requests before logging.
      client.prepareReconnect();
      final replay = client.receive(
        MutationResponse(
          requestId: mutation.requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
          logLines: const <String>['mutation log'],
        ),
      );
      expect(replay.events.whereType<FunctionLogEvent>(), isEmpty);

      // The mutation still resolves once its qualifying transition lands.
      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ),
      );
      expect(await future, <String, dynamic>{'ok': true});
    });

    test('mutation resolves when matching transition was already applied',
        () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', <String, dynamic>{
        'body': 'hello',
      });
      final mutation = client.drainOutgoing().single as Mutation;

      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(10)),
          modifications: const <StateModification>[],
        ),
      );

      client.receive(
        MutationResponse(
          requestId: mutation.requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
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

    test('canceled mutation is not replayed after reconnect', () async {
      final client = BaseClient();
      final request = client.trackMutation('messages:send', <String, dynamic>{
        'body': 'hello',
      });
      final expectation = expectLater(
        request.future,
        throwsA(isA<TimeoutException>()),
      );

      client.cancelMutation(request.requestId, TimeoutException('timed out'));

      await expectation;
      expect(client.prepareReconnect(), isEmpty);
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

    test('canceled action is not replayed after reconnect', () async {
      final client = BaseClient();
      final request = client.trackAction('messages:notify', <String, dynamic>{
        'body': 'hello',
      });
      final expectation = expectLater(
        request.future,
        throwsA(isA<TimeoutException>()),
      );

      client.cancelAction(request.requestId, TimeoutException('timed out'));

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

    test('ping is ignored by sync layer', () {
      final client = BaseClient();
      final result = client.receive(const Ping());
      expect(result.outgoing, isEmpty);
      expect(result.events, isEmpty);
    });

    test('auth error produces auth error event', () {
      final client = BaseClient();
      final result = client.receive(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
      );
      expect(result.events.single, isA<AuthErrorEvent>());
    });

    test('fatal error produces fatal error event', () {
      final client = BaseClient();
      final result = client.receive(const FatalError(error: 'boom'));
      expect(result.events.single, isA<FatalErrorEvent>());
      expect((result.events.single as FatalErrorEvent).error, 'boom');
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

    test('requeued query set changes preserve version chain', () {
      final client = BaseClient();
      client.subscribe('messages:list', const <String, dynamic>{
        'channel': 'general',
      });
      client.subscribe('messages:byAuthor', const <String, dynamic>{
        'author': 'ada',
      });

      final sentBatch = client.drainOutgoing();
      client.requeueOutgoing(sentBatch.skip(1));
      client.subscribe('messages:recent', const <String, dynamic>{});

      final replayBatch = client.drainOutgoing(assumeSent: false);
      expect(replayBatch, hasLength(2));

      final requeued = replayBatch.first as ModifyQuerySet;
      final newer = replayBatch.last as ModifyQuerySet;
      expect(requeued.baseVersion, 1);
      expect(requeued.newVersion, 2);
      expect(newer.baseVersion, 2);
      expect(newer.newVersion, 3);
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

  group('BaseClient.hasSyncedPastLastReconnect', () {
    test('a fresh client is synced', () {
      expect(BaseClient().hasSyncedPastLastReconnect, isTrue);
    });

    test('unsynced after reconnect until queries and auth are confirmed', () {
      final client = BaseClient();
      client.subscribe('messages:list', const <String, dynamic>{
        'channel': 'general',
      });
      client.setAuth(tokenType: 'User', token: 'token-123');
      client.drainOutgoing();
      expect(client.hasSyncedPastLastReconnect, isTrue);

      // The query has no prior remote result and auth is re-sent, so both are
      // outstanding after the restart.
      final reconnect = client.prepareReconnect();
      expect(client.hasSyncedPastLastReconnect, isFalse);

      final querySet = reconnect.whereType<ModifyQuerySet>().single;
      final queryId = (querySet.modifications.single as Add).queryId;

      // Confirm the query (querySet 0 -> 1); auth still outstanding.
      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: queryId,
              value: const <String, dynamic>{'body': 'hi'},
            ),
          ],
        ),
      );
      expect(client.hasSyncedPastLastReconnect, isFalse);

      // Confirm auth via an identity-advancing transition (identity 0 -> 1).
      client.receive(
        Transition(
          startVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          endVersion: StateVersion(querySet: 1, identity: 1, ts: encodeTs(2)),
          modifications: const <StateModification>[],
        ),
      );
      expect(client.hasSyncedPastLastReconnect, isTrue);
    });

    test('unsynced after reconnect until in-flight requests resolve', () async {
      final client = BaseClient();
      final future = client.mutate('messages:send', const <String, dynamic>{
        'body': 'hi',
      });
      client.drainOutgoing();
      expect(client.hasSyncedPastLastReconnect, isTrue);

      // The mutation is re-queued by the reconnect, so the request side is
      // outstanding even though there are no queries or auth.
      client.prepareReconnect();
      expect(client.hasSyncedPastLastReconnect, isFalse);

      client.receive(
        MutationResponse(
          requestId: 0,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(4),
        ),
      );
      expect(client.hasSyncedPastLastReconnect, isFalse);

      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 0, ts: encodeTs(4)),
          modifications: const <StateModification>[],
        ),
      );
      expect(client.hasSyncedPastLastReconnect, isTrue);
      expect(await future, const <String, dynamic>{'ok': true});
    });

    test('both the query side and the request side must be synced', () {
      final client = BaseClient();
      client.subscribe('messages:list', const <String, dynamic>{
        'channel': 'general',
      });
      unawaited(
        client.mutate('messages:send', const <String, dynamic>{'body': 'hi'}),
      );
      client.drainOutgoing();

      final reconnect = client.prepareReconnect();
      expect(client.hasSyncedPastLastReconnect, isFalse);

      final querySet = reconnect.whereType<ModifyQuerySet>().single;
      final queryId = (querySet.modifications.single as Add).queryId;

      // Confirm the query but leave the mutation pending.
      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: queryId,
              value: const <String, dynamic>{'body': 'hi'},
            ),
          ],
        ),
      );

      // The local (query/auth) side is synced, but the combined flag stays
      // false because a request is still in flight.
      expect(client.localState.hasSyncedPastLastReconnect(), isTrue);
      expect(client.hasSyncedPastLastReconnect, isFalse);
    });

    test('pause buffers work and resume replays it before queued mutations',
        () {
      final client = BaseClient();
      client.pause();
      expect(client.isPaused, isTrue);

      // A subscribe and auth set while paused emit nothing immediately; only a
      // mutation queued while paused sits in the outgoing buffer.
      client.subscribe('messages:list', const <String, dynamic>{});
      client.setAuth(tokenType: 'User', token: 'tok');
      client.mutate('messages:send', const <String, dynamic>{'body': 'hi'});
      final queuedWhilePaused = client.drainOutgoing();
      expect(queuedWhilePaused, hasLength(1));
      expect(queuedWhilePaused.single, isA<Mutation>());

      // Re-queue the mutation the assertion above drained, then resume.
      client.mutate('messages:send', const <String, dynamic>{'body': 'hi'});
      final resumeMessages = client.resume();
      expect(client.isPaused, isFalse);
      // Resume order: auth first, then the coalesced query-set, then the
      // queued mutation.
      expect(resumeMessages[0], isA<Authenticate>());
      expect(resumeMessages[1], isA<ModifyQuerySet>());
      expect(resumeMessages[2], isA<Mutation>());
    });

    test('pause emits an auth clear before queued mutations on resume', () {
      final client = BaseClient();
      client.setAuth(tokenType: 'User', token: 'tok');
      client.drainOutgoing();

      client.pause();
      client.clearAuth();
      client.mutate('messages:send', const <String, dynamic>{'body': 'hi'});
      final queuedWhilePaused = client.drainOutgoing();
      expect(queuedWhilePaused.single, isA<Mutation>());

      client.mutate('messages:send', const <String, dynamic>{'body': 'hi'});
      final resumeMessages = client.resume();
      expect(resumeMessages[0], isA<Authenticate>());
      expect((resumeMessages[0] as Authenticate).tokenType, 'None');
      expect(resumeMessages[1], isA<Mutation>());
    });

    test('a stale auth transition does not confirm auth', () {
      final client = BaseClient();
      client.setAuth(tokenType: 'User', token: 'a'); // authVersion -> 1
      client.setAuth(tokenType: 'User', token: 'b'); // authVersion -> 2
      client.drainOutgoing();

      final result = client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 1, ts: encodeTs(1)),
          modifications: const <StateModification>[],
        ),
      );

      // Identity advanced (0 -> 1) but the client already moved to auth version
      // 2, so this transition is stale and must not confirm auth.
      expect(result.events.whereType<AuthConfirmedEvent>(), isEmpty);
    });

    test('a current auth transition confirms auth', () {
      final client = BaseClient();
      client.setAuth(tokenType: 'User', token: 'a'); // authVersion -> 1
      client.drainOutgoing();

      final result = client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 1, ts: encodeTs(1)),
          modifications: const <StateModification>[],
        ),
      );

      expect(result.events.whereType<AuthConfirmedEvent>(), isNotEmpty);
    });
  });

  group('BaseClient optimistic updates', () {
    // Subscribes to messages:list and seeds it with [initial] from the server.
    (BaseClient, int) seeded(List<String> initial) {
      final client = BaseClient();
      final registration =
          client.subscribe('messages:list', const <String, dynamic>{});
      client.drainOutgoing();
      client.receive(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: initial),
          ],
        ),
      );
      return (client, registration.queryId);
    }

    List<dynamic> listOf(BaseClientEvent event) {
      return ((event as QueryUpdateEvent).result as StoredQuerySuccess).value
          as List<dynamic>;
    }

    // An optimistic update that appends [body] to messages:list.
    void Function(dynamic) append(String body) {
      return (store) {
        final list = (store.getQuery('messages:list') as List<dynamic>?) ??
            const <dynamic>[];
        store.setQuery('messages:list', const <String, dynamic>{}, <dynamic>[
          ...list,
          body,
        ]);
      };
    }

    test('overlays the subscribed query value immediately', () {
      final (client, queryId) = seeded(<String>['a']);
      final request = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
      );
      final events =
          client.applyOptimisticUpdate(append('b'), request.requestId);

      final event = events.single as QueryUpdateEvent;
      expect(event.queryId, queryId);
      expect(event.hasPendingWrites, isTrue);
      expect(listOf(event), <String>['a', 'b']);
    });

    test('optimistic value survives an interleaved server load', () {
      final (client, queryId) = seeded(<String>['a']);
      final request = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
      );
      client.applyOptimisticUpdate(append('b'), request.requestId);

      // A different message arrives from the server while the mutation pends.
      final result = client.receive(
        Transition(
          startVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(2)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: const <String>['a', 'c']),
          ],
        ),
      );

      // The optimistic 'b' replays on top of the new server value.
      final event = result.events.whereType<QueryUpdateEvent>().single;
      expect(event.hasPendingWrites, isTrue);
      expect(listOf(event), <String>['a', 'c', 'b']);
    });

    test('drops a throwing replay layer without reconnecting', () {
      final (client, queryId) = seeded(<String>['a']);
      final poison = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'poison'},
      );
      var poisonRuns = 0;
      client.applyOptimisticUpdate((store) {
        poisonRuns += 1;
        if (poisonRuns > 1) {
          throw StateError('poisoned replay');
        }
        final list = (store.getQuery('messages:list') as List<dynamic>?) ??
            const <dynamic>[];
        store.setQuery('messages:list', const <String, dynamic>{}, <dynamic>[
          ...list,
          'poison',
        ]);
      }, poison.requestId);

      final safe = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'safe'},
      );
      client.applyOptimisticUpdate(append('safe'), safe.requestId);
      client.drainOutgoing();

      final result = client.receive(
        Transition(
          startVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(2)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: const <String>['server']),
          ],
        ),
      );

      expect(result.events.whereType<ReconnectRequiredEvent>(), isEmpty);
      expect(
        listOf(result.events.whereType<QueryUpdateEvent>().single),
        <String>['server', 'safe'],
      );
    });

    test('drops the layer exactly when its transition lands', () async {
      final (client, queryId) = seeded(<String>['a']);
      final request = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
      );
      client.drainOutgoing();
      client.applyOptimisticUpdate(append('b'), request.requestId);

      // Server commits the mutation; its ts is still in the future, so the
      // layer is parked (read-your-writes) and not yet dropped.
      final parked = client.receive(
        MutationResponse(
          requestId: request.requestId,
          success: true,
          result: const <String, dynamic>{'ok': true},
          ts: encodeTs(5),
        ),
      );
      expect(parked.events.whereType<QueryUpdateEvent>(), isEmpty);

      // The transition carrying the ts both resolves the future and drops the
      // layer, replacing the optimistic value with the authoritative server one
      // (no flicker, no duplicate 'b').
      final landed = client.receive(
        Transition(
          startVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(5)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: const <String>['a', 'b']),
          ],
        ),
      );
      expect(
        landed.events.whereType<QueryUpdateEvent>().single.hasPendingWrites,
        isFalse,
      );
      expect(
        listOf(landed.events.whereType<QueryUpdateEvent>().single),
        <String>['a', 'b'],
      );
      expect(await request.future, const <String, dynamic>{'ok': true});

      // A later server update does not re-add the dropped optimistic value.
      final later = client.receive(
        Transition(
          startVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(5)),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(6)),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: queryId,
              value: const <String>['a', 'b', 'x'],
            ),
          ],
        ),
      );
      expect(
        listOf(later.events.whereType<QueryUpdateEvent>().single),
        <String>['a', 'b', 'x'],
      );
    });

    test('rolls back the layer when its mutation fails', () async {
      final (client, queryId) = seeded(<String>['a']);
      final request = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
      );
      client.drainOutgoing();
      client.applyOptimisticUpdate(append('b'), request.requestId);

      final result = client.receive(
        MutationResponse(
          requestId: request.requestId,
          success: false,
          errorMessage: 'rejected',
        ),
      );
      final event = result.events.whereType<QueryUpdateEvent>().single;
      expect(event.queryId, queryId);
      expect(listOf(event), <String>['a']);
      await expectLater(request.future, throwsA(isA<ConvexException>()));
    });

    test('rolls back optimistic-only value to loading when mutation fails',
        () async {
      final client = BaseClient();
      final registration =
          client.subscribe('messages:list', const <String, dynamic>{});
      client.drainOutgoing();
      final request = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
      );
      client.drainOutgoing();

      final optimistic = client.applyOptimisticUpdate(
        append('b'),
        request.requestId,
      );
      expect(
        listOf(optimistic.whereType<QueryUpdateEvent>().single),
        <String>['b'],
      );

      final expectation =
          expectLater(request.future, throwsA(isA<ConvexException>()));
      final result = client.receive(
        MutationResponse(
          requestId: request.requestId,
          success: false,
          errorMessage: 'rejected',
        ),
      );

      final event = result.events.whereType<QueryLoadingEvent>().single;
      expect(event.queryId, registration.queryId);
      expect(event.hasPendingWrites, isFalse);
      await expectation;
    });

    test('rolls back the layer when its mutation is canceled', () async {
      final (client, queryId) = seeded(<String>['a']);
      final request = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
      );
      client.drainOutgoing();
      client.applyOptimisticUpdate(append('b'), request.requestId);
      final expectation =
          expectLater(request.future, throwsA(isA<TimeoutException>()));

      // A timeout/cancel drops the layer even though no server response arrives.
      final events = client.cancelMutation(
        request.requestId,
        TimeoutException('timed out'),
      );
      final event = events.whereType<QueryUpdateEvent>().single;
      expect(event.queryId, queryId);
      expect(listOf(event), <String>['a']);
      await expectation;
    });

    test('stacks concurrent layers and rolls each back independently',
        () async {
      final (client, _) = seeded(<String>['a']);
      final first = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
      );
      client.applyOptimisticUpdate(append('b'), first.requestId);
      final second = client.trackMutation(
        'messages:send',
        const <String, dynamic>{'body': 'c'},
      );
      final stacked =
          client.applyOptimisticUpdate(append('c'), second.requestId);
      client.drainOutgoing();

      // Both layers are visible.
      expect(listOf(stacked.single), <String>['a', 'b', 'c']);

      // The first mutation fails: only its 'b' is removed; 'c' replays on top.
      final rollback = client.receive(
        MutationResponse(
          requestId: first.requestId,
          success: false,
          errorMessage: 'rejected',
        ),
      );
      expect(
        listOf(rollback.events.whereType<QueryUpdateEvent>().single),
        <String>['a', 'c'],
      );
      await expectLater(first.future, throwsA(isA<ConvexException>()));
    });
  });
}
