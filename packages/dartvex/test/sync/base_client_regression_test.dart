import 'dart:async';

import 'package:dartvex/src/exceptions.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/sync/base_client.dart';
import 'package:dartvex/src/sync/local_state.dart';
import 'package:dartvex/src/sync/optimistic_updates.dart';
import 'package:dartvex/src/sync/remote_query_set.dart';
import 'package:dartvex/src/sync/request_manager.dart';
import 'package:test/test.dart';

/// Regression tests for the post-release review fixes in the sync layer.
void main() {
  Transition transition({
    required StateVersion start,
    required StateVersion end,
    List<StateModification> modifications = const <StateModification>[],
  }) {
    return Transition(
      startVersion: start,
      endVersion: end,
      modifications: modifications,
    );
  }

  StateVersion version(int querySet, int identity, int ts) =>
      StateVersion(querySet: querySet, identity: identity, ts: encodeTs(ts));

  OptimisticUpdate setList(List<String> value) => (store) =>
      store.setQuery('messages:list', const <String, dynamic>{}, value);

  Object? valueOf(BaseClientEvent? event) =>
      ((event as QueryUpdateEvent).result as StoredQuerySuccess).value;

  group('resume ordering (F8)', () {
    test('resume messages go after already-versioned control messages', () {
      final client = BaseClient();
      // A query-set change versioned before the pause and still queued (the
      // paused socket refused it and the flush put it back).
      client.subscribe('a:list', const <String, dynamic>{});
      final mutation =
          client.trackMutation('a:send', const <String, dynamic>{});
      mutation.future.ignore();
      client.pause();
      client.setAuth(tokenType: 'User', token: 'jwt');
      client.subscribe('b:list', const <String, dynamic>{});

      final messages = client.resume();

      expect(
        messages.map((message) => message.runtimeType).toList(),
        <Type>[ModifyQuerySet, Authenticate, ModifyQuerySet, Mutation],
      );
      final first = messages[0] as ModifyQuerySet;
      final second = messages[2] as ModifyQuerySet;
      expect(first.baseVersion, 0);
      expect(first.newVersion, 1);
      expect(second.baseVersion, 1);
      expect(second.newVersion, 2);
    });

    test('a pre-pause unsent Authenticate stays ahead of the resume one', () {
      final client = BaseClient();
      client.setAuth(tokenType: 'User', token: 'first');
      client.pause();
      client.setAuth(tokenType: 'User', token: 'second');

      final messages = client.resume().whereType<Authenticate>().toList();

      expect(messages.map((message) => message.baseVersion), <int>[0, 1]);
      expect(messages.map((message) => message.value), <String?>[
        'first',
        'second',
      ]);
    });
  });

  group('result cache (F56/F160/F170)', () {
    test('a transition from the previous identity does not refill the cache',
        () {
      final client = BaseClient();
      final registration =
          client.subscribe('profile:me', const <String, dynamic>{});
      client.drainOutgoing();
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: 'user-a'),
          ],
        ),
      );
      expect(
        (client.cachedResultForQuery('profile:me', const <String, dynamic>{})
                as StoredQuerySuccess)
            .value,
        'user-a',
      );

      client.setAuth(tokenType: 'User', token: 'token-b');
      expect(
        client.cachedResultForQuery('profile:me', const <String, dynamic>{}),
        isNull,
      );

      // Still computed under identity 0 (user A).
      client.receive(
        transition(
          start: version(1, 0, 1),
          end: version(1, 0, 2),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: 'user-a-2'),
          ],
        ),
      );
      expect(
        client.cachedResultForQuery('profile:me', const <String, dynamic>{}),
        isNull,
      );

      // The server applied identity 1 (user B).
      client.receive(
        transition(
          start: version(1, 0, 2),
          end: version(1, 1, 3),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: 'user-b'),
          ],
        ),
      );
      expect(
        (client.cachedResultForQuery('profile:me', const <String, dynamic>{})
                as StoredQuerySuccess)
            .value,
        'user-b',
      );
    });

    test('an auth change while paused waits for the resumed identity', () {
      final client = BaseClient();
      final registration =
          client.subscribe('profile:me', const <String, dynamic>{});
      client.drainOutgoing();
      client.pause();
      client.setAuth(tokenType: 'User', token: 'token-b');
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: 'user-a'),
          ],
        ),
      );
      expect(
        client.cachedResultForQuery('profile:me', const <String, dynamic>{}),
        isNull,
      );
    });

    test('clearAuth empties the cache', () {
      final client = BaseClient();
      final registration =
          client.subscribe('inbox:list', const <String, dynamic>{});
      client.drainOutgoing();
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: 'mail'),
          ],
        ),
      );
      client.clearAuth();
      expect(
        client.cachedResultForQuery('inbox:list', const <String, dynamic>{}),
        isNull,
      );
    });

    test('the cache evicts the least-recently-written entry past 256', () {
      final client = BaseClient();
      final modifications = <StateModification>[];
      for (var index = 0; index < 257; index += 1) {
        final registration = client.subscribe(
          'items:get',
          <String, dynamic>{'id': index},
        );
        modifications.add(
          QueryUpdated(queryId: registration.queryId, value: index),
        );
      }
      client.drainOutgoing();
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(257, 0, 1),
          modifications: modifications,
        ),
      );

      expect(
        client.cachedResultForQuery('items:get', const <String, dynamic>{
          'id': 0,
        }),
        isNull,
      );
      expect(
        client.cachedResultForQuery('items:get', const <String, dynamic>{
          'id': 1,
        }),
        isA<StoredQuerySuccess>(),
      );
      expect(
        client.cachedResultForQuery('items:get', const <String, dynamic>{
          'id': 256,
        }),
        isA<StoredQuerySuccess>(),
      );
    });

    test('a mismatched startVersion requests a reconnect without changes', () {
      final client = BaseClient();
      final registration =
          client.subscribe('messages:list', const <String, dynamic>{});
      client.drainOutgoing();
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: 'v1'),
          ],
        ),
      );

      final result = client.receive(
        transition(
          start: version(5, 0, 9),
          end: version(6, 0, 10),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: 'bogus'),
          ],
        ),
      );

      expect(result.events.single, isA<ReconnectRequiredEvent>());
      expect(
        (client.currentResultForQuery(registration.queryId)
                as StoredQuerySuccess)
            .value,
        'v1',
      );
      expect(client.maxObservedTimestamp, encodeTs(1));
    });
  });

  group('optimistic layers', () {
    (BaseClient, int) seeded() {
      final client = BaseClient();
      final registration =
          client.subscribe('messages:list', const <String, dynamic>{});
      client.drainOutgoing();
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: <String>['a']),
          ],
        ),
      );
      return (client, registration.queryId);
    }

    test('failPendingRequests rolls back optimistic layers (F59)', () async {
      final (client, queryId) = seeded();
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      client.applyOptimisticUpdate(
        setList(<String>['a', 'draft']),
        request.requestId,
      );
      final failure = expectLater(request.future, throwsA(anything));

      final events = client.failPendingRequests('FatalError: boom');

      final event = events.single as QueryUpdateEvent;
      expect(event.queryId, queryId);
      expect(event.hasPendingWrites, isFalse);
      expect(valueOf(event), <String>['a']);
      expect(
        client.optimisticResultForQuery(
          'messages:list',
          const <String, dynamic>{},
        ),
        isA<StoredQuerySuccess>().having(
          (result) => result.value,
          'value',
          <String>['a'],
        ),
      );
      await failure;
    });

    test(
        'a rebuild before the first post-reconnect transition keeps values '
        '(F63)', () async {
      final (client, queryId) = seeded();
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      client.applyOptimisticUpdate(
        setList(<String>['a', 'draft']),
        request.requestId,
      );
      client.drainOutgoing();
      client.handleDisconnect('network');
      client.prepareReconnect();

      final failure = expectLater(request.future, throwsA(anything));
      final result = client.receive(
        MutationResponse(
          requestId: request.requestId,
          success: false,
          errorMessage: 'rejected',
        ),
      );

      expect(result.events.whereType<QueryLoadingEvent>(), isEmpty);
      final update = result.events.whereType<QueryUpdateEvent>().single;
      expect(update.queryId, queryId);
      expect(valueOf(update), <String>['a']);
      await failure;

      // The first transition of the new connection replaces the fallback.
      final fresh = client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 2),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: <String>['fresh']),
          ],
        ),
      );
      expect(valueOf(fresh.events.whereType<QueryUpdateEvent>().single),
          <String>['fresh']);
    });

    test(
        'currentQueryEvent reflects an optimistic update applied after the '
        'transition was received (F66)', () {
      final (client, queryId) = seeded();
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      client.applyOptimisticUpdate(setList(<String>['opt']), request.requestId);

      final current = client.currentQueryEvent(queryId) as QueryUpdateEvent;
      expect(current.hasPendingWrites, isTrue);
      expect(valueOf(current), <String>['opt']);
      expect(client.currentQueryEvent(queryId + 100), isNull);
    });

    test('applyOptimisticUpdate reports each touched query once (F166)', () {
      final (client, _) = seeded();
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      final events = client.applyOptimisticUpdate((store) {
        store.setQuery('messages:list', const <String, dynamic>{}, <String>[
          'x',
        ]);
        store.setQuery('messages:list', const <String, dynamic>{}, <String>[
          'x',
          'y',
        ]);
      }, request.requestId);

      expect(events, hasLength(1));
      expect(valueOf(events.single), <String>['x', 'y']);
    });

    test('a replay failure is reported, and the layer still dropped (F230)',
        () {
      final (client, queryId) = seeded();
      final reported = <(int, Object)>[];
      client.onOptimisticReplayError = (requestId, error, _) {
        reported.add((requestId, error));
      };
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      var runs = 0;
      client.applyOptimisticUpdate((store) {
        runs += 1;
        if (runs > 1) {
          throw StateError('replay failed');
        }
        store.setQuery('messages:list', const <String, dynamic>{}, <String>[
          'opt',
        ]);
      }, request.requestId);

      final result = client.receive(
        transition(
          start: version(1, 0, 1),
          end: version(1, 0, 2),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: <String>['server']),
          ],
        ),
      );

      expect(reported, hasLength(1));
      expect(reported.single.$1, request.requestId);
      expect(reported.single.$2, isA<StateError>());
      expect(valueOf(result.events.whereType<QueryUpdateEvent>().single),
          <String>['server']);
    });
  });

  group('mutation results', () {
    test(
        'a timed-out mutation whose success already arrived resolves with '
        'its result and keeps its layer (F163)', () async {
      final client = BaseClient();
      final registration =
          client.subscribe('messages:list', const <String, dynamic>{});
      client.drainOutgoing();
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: <String>['a']),
          ],
        ),
      );
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      client.applyOptimisticUpdate(
        setList(<String>['a', 'b']),
        request.requestId,
      );
      client.drainOutgoing();

      expect(client.completeConfirmedMutation(request.requestId), isFalse);

      client.receive(
        MutationResponse(
          requestId: request.requestId,
          success: true,
          result: 'ok',
          ts: encodeTs(5),
        ),
      );
      expect(client.completeConfirmedMutation(request.requestId), isTrue);
      expect(await request.future, 'ok');
      expect(
        client.hasOptimisticUpdateForQuery(
          'messages:list',
          const <String, dynamic>{},
        ),
        isTrue,
      );

      // The transition still resolves (and drops) it without double-completing.
      final resolved = client.receive(
        transition(
          start: version(1, 0, 1),
          end: version(1, 0, 5),
          modifications: <StateModification>[
            QueryUpdated(
              queryId: registration.queryId,
              value: <String>['a', 'b'],
            ),
          ],
        ),
      );
      expect(resolved.events.whereType<QueryUpdateEvent>().single, isNotNull);
      expect(
        client.hasOptimisticUpdateForQuery(
          'messages:list',
          const <String, dynamic>{},
        ),
        isFalse,
      );
      expect(client.inflightMutations, 0);
    });

    test('an undecodable mutation result fails only that mutation (C18)',
        () async {
      final client = BaseClient();
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      client.drainOutgoing();
      final response = ServerMessage.fromJson(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': request.requestId,
        'success': true,
        'result': const <String, dynamic>{r'$futureTag': 1},
        'ts': encodeTs(3),
        'logLines': const <String>[],
      });

      final failure = expectLater(
        request.future,
        throwsA(
          isA<ConvexException>().having(
            (error) => error.message,
            'message',
            contains('could not decode the mutation result'),
          ),
        ),
      );
      client.receive(response);
      await failure;
      expect(client.inflightMutations, 0);
      // Not replayed on the next reconnect.
      expect(client.prepareReconnect().whereType<Mutation>(), isEmpty);
    });

    test('an undecodable action result fails only that action (C18)', () async {
      final client = BaseClient();
      final request =
          client.trackAction('files:resolve', const <String, dynamic>{});
      client.drainOutgoing();
      final failure =
          expectLater(request.future, throwsA(isA<ConvexException>()));
      client.receive(
        ServerMessage.fromJson(<String, dynamic>{
          'type': 'ActionResponse',
          'requestId': request.requestId,
          'success': true,
          'result': const <String, dynamic>{r'$futureTag': 1},
          'logLines': const <String>[],
        }),
      );
      await failure;
    });
  });

  group('identity change (C30)', () {
    test('requests issued before an identity change fail on reconnect',
        () async {
      final client = BaseClient();
      // First connection.
      client.prepareReconnect();
      final registration =
          client.subscribe('messages:list', const <String, dynamic>{});
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: <String>['a']),
          ],
        ),
      );
      final asUserA =
          client.trackMutation('messages:send', const <String, dynamic>{});
      client.applyOptimisticUpdate(
        setList(<String>['a', 'from-a']),
        asUserA.requestId,
      );
      final actionAsUserA =
          client.trackAction('mail:send', const <String, dynamic>{});
      client.drainOutgoing(assumeSent: false);

      client.markIdentityChange();
      client.setAuth(tokenType: 'User', token: 'user-b');
      final asUserB =
          client.trackMutation('messages:send', const <String, dynamic>{});
      asUserB.future.ignore();
      client.drainOutgoing(assumeSent: false);

      final mutationFailure = expectLater(
        asUserA.future,
        throwsA(
          isA<ConvexException>().having(
            (error) => error.message,
            'message',
            RequestManager.authChangedMessage,
          ),
        ),
      );
      final actionFailure =
          expectLater(actionAsUserA.future, throwsA(isA<ConvexException>()));

      client.handleDisconnect('network');
      final replay = client.prepareReconnect();

      final replayedIds = <int>[
        for (final message in replay)
          if (message is RequestMessage) message.requestId,
      ];
      expect(replayedIds, <int>[asUserB.requestId]);
      await mutationFailure;
      await actionFailure;

      final events = client.takeReconnectEvents();
      final update = events.whereType<QueryUpdateEvent>().single;
      expect(valueOf(update), <String>['a']);
      expect(client.takeReconnectEvents(), isEmpty);
    });

    test('requests queued before the very first connection are kept', () {
      final client = BaseClient();
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      request.future.ignore();
      client.markIdentityChange();
      client.setAuth(tokenType: 'User', token: 'user-b');

      final replay = client.prepareReconnect();

      expect(
        replay.whereType<Mutation>().map((message) => message.requestId),
        <int>[request.requestId],
      );
    });

    test('a confirmed mutation awaiting its transition is still replayed', () {
      final client = BaseClient();
      client.prepareReconnect();
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      request.future.ignore();
      client.drainOutgoing();
      client.receive(
        MutationResponse(
          requestId: request.requestId,
          success: true,
          result: 'ok',
          ts: encodeTs(10),
        ),
      );
      client.markIdentityChange();

      final replay = client.prepareReconnect();

      expect(
        replay.whereType<Mutation>().map((message) => message.requestId),
        <int>[request.requestId],
      );
    });
  });

  group('query tokens (F67)', () {
    test('int and integral double args share a token', () {
      expect(
        LocalSyncState.serializeQueryToken('messages:list', <String, dynamic>{
          'limit': 10,
        }),
        LocalSyncState.serializeQueryToken('messages:list', <String, dynamic>{
          'limit': 10.0,
        }),
      );
    });

    test('an optimistic update keyed with an int finds a double subscription',
        () {
      final client = BaseClient();
      final registration = client.subscribe('messages:list', <String, dynamic>{
        'limit': 10.0,
      });
      client.drainOutgoing();
      client.receive(
        transition(
          start: const StateVersion.initial(),
          end: version(1, 0, 1),
          modifications: <StateModification>[
            QueryUpdated(queryId: registration.queryId, value: <String>['a']),
          ],
        ),
      );
      final request =
          client.trackMutation('messages:send', const <String, dynamic>{});
      final events = client.applyOptimisticUpdate((store) {
        final current = store.getQuery('messages:list', <String, dynamic>{
          'limit': 10,
        }) as List<dynamic>;
        store.setQuery('messages:list', <String, dynamic>{
          'limit': 10
        }, <dynamic>[
          ...current,
          'b',
        ]);
      }, request.requestId);

      final update = events.single as QueryUpdateEvent;
      expect(update.queryId, registration.queryId);
      expect(valueOf(update), <String>['a', 'b']);
    });
  });
}
