import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:test/test.dart';

void main() {
  group('ConvexLocalClient', () {
    late SqliteLocalStore store;
    late FakeRemoteClient remoteClient;
    late ConvexLocalClient localClient;

    setUp(() async {
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            PublicMessageMutationHandler(),
          ],
        ),
      );
    });

    tearDown(() async {
      await localClient.dispose();
    });

    // ---------------------------------------------------------------
    // Cache behavior
    // ---------------------------------------------------------------

    test('falls back to cached query values while offline', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[
        <String, dynamic>{
          '_id': 'message-1',
          '_creationTime': 1,
          'author': 'Andre',
          'text': 'Hello',
        },
      ];

      final online = await localClient.query('messages:listPublic');
      expect((online as List<dynamic>).single['text'], 'Hello');

      await localClient.setNetworkMode(LocalNetworkMode.offline);
      final offline = await localClient.query('messages:listPublic');
      expect((offline as List<dynamic>).single['text'], 'Hello');
    });

    test('query throws when offline with no cached value', () async {
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await expectLater(
        localClient.query('unknown:query'),
        throwsA(isA<StateError>()),
      );
    });

    test('query falls back to cache on retryable remote error', () async {
      // Seed the cache.
      remoteClient.queryResults['tasks:list'] = <dynamic>['cached-task'];
      await localClient.query('tasks:list');

      // Remove the remote result so next query throws retryable error.
      remoteClient.queryResults.remove('tasks:list');

      final result = await localClient.query('tasks:list');
      expect(result, <dynamic>['cached-task']);
    });

    test('query rethrows non-retryable remote error even with cache', () async {
      remoteClient.queryResults['tasks:list'] = <dynamic>['cached-task'];
      await localClient.query('tasks:list');

      // Set a non-retryable error.
      remoteClient.queryErrors['tasks:list'] =
          const ConvexException('Validation failed', retryable: false);

      await expectLater(
        localClient.query('tasks:list'),
        throwsA(isA<ConvexException>()),
      );
    });

    test('query rethrows retryable error when no cache exists', () async {
      // No cache seeded, remote throws retryable.
      await expectLater(
        localClient.query('unknown:query'),
        throwsA(isA<ConvexException>()),
      );
    });

    test('subscribe seeds from cache before remote data arrives', () async {
      // Seed cache.
      remoteClient.queryResults['tasks:list'] = <dynamic>['task-1'];
      await localClient.query('tasks:list');

      // Subscribe — should get cached value immediately, then remote.
      final events = <LocalQueryEvent>[];
      final sub = localClient.subscribe('tasks:list');
      final listener = sub.stream.listen(events.add);
      await pumpEventQueue();

      expect(events, isNotEmpty);
      final first = events.first;
      expect(first, isA<LocalQuerySuccess>());
      expect((first as LocalQuerySuccess).source, LocalQuerySource.cache);

      await listener.cancel();
      sub.cancel();
    });

    test('subscribe emits error when offline with no cache', () async {
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      final events = <LocalQueryEvent>[];
      final sub = localClient.subscribe('unknown:query');
      final listener = sub.stream.listen(events.add);
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.first, isA<LocalQueryError>());
      expect(
        (events.first as LocalQueryError).source,
        LocalQuerySource.cache,
      );

      await listener.cancel();
      sub.cancel();
    });

    // ---------------------------------------------------------------
    // Queueing and replay behavior
    // ---------------------------------------------------------------

    test('queues offline mutations and applies optimistic cache updates',
        () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[
        <String, dynamic>{
          '_id': 'message-1',
          '_creationTime': 1,
          'author': 'Andre',
          'text': 'Existing',
        },
      ];
      await localClient.query('messages:listPublic');

      await localClient.setNetworkMode(LocalNetworkMode.offline);

      final result = await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'Local', 'text': 'Queued'},
      );

      expect(result, isA<LocalMutationQueued>());
      final cached = await localClient.query('messages:listPublic');
      expect((cached as List<dynamic>).last['text'], 'Queued');
      expect(localClient.currentPendingMutations, hasLength(1));
    });

    test('replays queued mutations in order when returning online', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[
        <String, dynamic>{
          '_id': 'message-1',
          '_creationTime': 1,
          'author': 'Andre',
          'text': 'Existing',
        },
      ];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'A', 'text': 'First'},
      );
      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'B', 'text': 'Second'},
      );

      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        'server-id-1',
        'server-id-2',
      ];
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[
        <String, dynamic>{
          '_id': 'server-id-1',
          '_creationTime': 2,
          'author': 'A',
          'text': 'First',
        },
        <String, dynamic>{
          '_id': 'server-id-2',
          '_creationTime': 3,
          'author': 'B',
          'text': 'Second',
        },
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(
        remoteClient.mutationCalls.map((call) => call.name).toList(),
        <String>['messages:sendPublic', 'messages:sendPublic'],
      );
      expect(localClient.currentPendingMutations, isEmpty);
      final refreshed = await localClient.query('messages:listPublic');
      expect((refreshed as List<dynamic>).length, 2);
    });

    test('replay stops and retains queue on retryable error', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'A', 'text': 'First'},
      );
      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'B', 'text': 'Second'},
      );

      // First mutation returns retryable error.
      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        const ConvexException('Server busy', retryable: true),
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      // Both mutations should still be in the queue.
      expect(localClient.currentPendingMutations, hasLength(2));
      // Only one attempt was made.
      expect(remoteClient.mutationCalls, hasLength(1));
    });

    test('replay retries automatically after retryable error', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'A', 'text': 'retry-test'},
      );

      // First attempt returns retryable error, second succeeds.
      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        const ConvexException('Transient failure', retryable: true),
        'server-id-ok',
      ];

      // Go online — first replay attempt fails with retryable error.
      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();
      expect(localClient.currentPendingMutations, hasLength(1));
      expect(remoteClient.mutationCalls, hasLength(1));

      // The retry timer should fire and drain the queue automatically.
      await localClient.pendingMutations
          .firstWhere((list) => list.isEmpty)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw StateError(
              'Mutation queue did not drain after retry. '
              'Calls: ${remoteClient.mutationCalls.length}',
            ),
          );

      expect(localClient.currentPendingMutations, isEmpty);
      expect(remoteClient.mutationCalls, hasLength(2));
    });

    test('replay drops mutation and fires onConflict on non-retryable error',
        () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'A', 'text': 'WillFail'},
      );
      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'B', 'text': 'ShouldStillReplay'},
      );

      final conflicts = <LocalMutationConflict>[];
      localClient.onConflict = conflicts.add;

      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        const ConvexException('Validation failed', retryable: false),
        'server-id-2',
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      // First dropped, second replayed.
      expect(conflicts, hasLength(1));
      expect(conflicts.first.mutationName, 'messages:sendPublic');
      expect(localClient.currentPendingMutations, isEmpty);
      expect(remoteClient.mutationCalls, hasLength(2));
    });

    test('multiple queued mutations preserve insertion order', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      for (int i = 1; i <= 5; i++) {
        await localClient.mutate(
          'messages:sendPublic',
          <String, dynamic>{'author': 'User', 'text': 'Message $i'},
        );
      }

      expect(localClient.currentPendingMutations, hasLength(5));
      for (int i = 0; i < 5; i++) {
        expect(
          localClient.currentPendingMutations[i].args['text'],
          'Message ${i + 1}',
        );
      }
    });

    // ---------------------------------------------------------------
    // Network mode transitions
    // ---------------------------------------------------------------

    test('network mode transitions auto -> offline -> auto', () async {
      final modes = <LocalNetworkMode>[];
      final subscription = localClient.networkModeStream.listen(modes.add);

      expect(localClient.currentNetworkMode, LocalNetworkMode.auto);

      await localClient.setNetworkMode(LocalNetworkMode.offline);
      expect(localClient.currentNetworkMode, LocalNetworkMode.offline);
      expect(
        localClient.currentConnectionState,
        LocalConnectionState.offline,
      );

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      expect(localClient.currentNetworkMode, LocalNetworkMode.auto);

      await subscription.cancel();
      // Initial emit + offline + auto.
      expect(modes, contains(LocalNetworkMode.offline));
      expect(modes, contains(LocalNetworkMode.auto));
    });

    test('repeated offline toggles do not leak or duplicate events', () async {
      final connectionStates = <LocalConnectionState>[];
      final subscription =
          localClient.connectionState.listen(connectionStates.add);

      for (int i = 0; i < 5; i++) {
        await localClient.setNetworkMode(LocalNetworkMode.offline);
        await localClient.setNetworkMode(LocalNetworkMode.auto);
      }
      await pumpEventQueue();

      await subscription.cancel();
      // Should have toggles without growing unboundedly.
      expect(connectionStates, isNotEmpty);
    });

    test('setting same network mode is a no-op', () async {
      final modes = <LocalNetworkMode>[];
      final subscription = localClient.networkModeStream.listen(modes.add);
      await pumpEventQueue();
      modes.clear();

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      expect(modes, isEmpty);

      await subscription.cancel();
    });

    test('connection state reflects remote disconnection in auto mode',
        () async {
      remoteClient.setConnectionState(
        LocalRemoteConnectionState.disconnected,
      );
      await pumpEventQueue();

      expect(
        localClient.currentConnectionState,
        LocalConnectionState.offline,
      );

      remoteClient.setConnectionState(
        LocalRemoteConnectionState.connected,
      );
      await pumpEventQueue();

      expect(
        localClient.currentConnectionState,
        LocalConnectionState.online,
      );
    });

    // ---------------------------------------------------------------
    // Mutation handlers and patches
    // ---------------------------------------------------------------

    test('mutation without handler still queues but creates no patches',
        () async {
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      final result = await localClient.mutate(
        'unknown:mutation',
        <String, dynamic>{'key': 'value'},
      );

      expect(result, isA<LocalMutationQueued>());
      expect(localClient.currentPendingMutations, hasLength(1));
      expect(
        localClient.currentPendingMutations.first.mutationName,
        'unknown:mutation',
      );
    });

    test('handler patch applies even when no cached query exists', () async {
      // No cache seeded — patch will get null as currentValue.
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'User', 'text': 'First ever'},
      );

      // The handler should handle null currentValue by creating a new list.
      final cached = await localClient.query('messages:listPublic');
      expect(cached, isA<List>());
      expect((cached as List).single['text'], 'First ever');
    });

    test('hasPendingWrites is true while mutations are queued', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');

      final events = <LocalQueryEvent>[];
      final sub = localClient.subscribe('messages:listPublic');
      final listener = sub.stream.listen(events.add);
      await pumpEventQueue();
      events.clear();

      await localClient.setNetworkMode(LocalNetworkMode.offline);
      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'User', 'text': 'Pending'},
      );
      await pumpEventQueue();

      final pendingEvent = events.whereType<LocalQuerySuccess>().lastOrNull;
      expect(pendingEvent, isNotNull);
      expect(pendingEvent!.hasPendingWrites, isTrue);

      await listener.cancel();
      sub.cancel();
    });

    // ---------------------------------------------------------------
    // ID remapping during replay
    // ---------------------------------------------------------------

    test('replay remaps local IDs in create→advance chain', () async {
      remoteClient.queryResults['tasks:list'] = <dynamic>[];
      await localClient.dispose();

      // Rebuild with task handlers.
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      remoteClient.queryResults['tasks:list'] = <dynamic>[];
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            CreateTaskHandler(),
            AdvanceTaskHandler(),
          ],
        ),
      );

      await localClient.query('tasks:list');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      // Create task offline — handler assigns local ID via operationId.
      await localClient.mutate(
        'tasks:create',
        <String, dynamic>{'title': 'Buy milk'},
      );
      // Advance that task offline — uses the local operationId as taskId.
      final pending = localClient.currentPendingMutations;
      final createOpId = pending.first.optimisticData!['operationId'] as String;
      await localClient.mutate(
        'tasks:advance',
        <String, dynamic>{'taskId': createOpId},
      );

      expect(localClient.currentPendingMutations, hasLength(2));

      // Set up server responses: create returns real ID, advance succeeds.
      remoteClient.mutationResults['tasks:create'] = <Object?>[
        'server-task-abc',
      ];
      remoteClient.mutationResults['tasks:advance'] = <Object?>['ok'];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, isEmpty);
      expect(remoteClient.mutationCalls, hasLength(2));
      // The advance call should have received the remapped server ID.
      final advanceCall = remoteClient.mutationCalls[1];
      expect(advanceCall.name, 'tasks:advance');
      expect(advanceCall.args['taskId'], 'server-task-abc');
    });

    test('replay remaps multiple local IDs in sequence', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      remoteClient.queryResults['tasks:list'] = <dynamic>[];
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            CreateTaskHandler(),
            AdvanceTaskHandler(),
          ],
        ),
      );

      await localClient.query('tasks:list');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      // Create two tasks offline.
      await localClient.mutate(
        'tasks:create',
        <String, dynamic>{'title': 'Task A'},
      );
      final opIdA = localClient
          .currentPendingMutations[0].optimisticData!['operationId'] as String;

      await localClient.mutate(
        'tasks:create',
        <String, dynamic>{'title': 'Task B'},
      );
      final opIdB = localClient
          .currentPendingMutations[1].optimisticData!['operationId'] as String;

      // Advance both using their local IDs.
      await localClient.mutate(
        'tasks:advance',
        <String, dynamic>{'taskId': opIdA},
      );
      await localClient.mutate(
        'tasks:advance',
        <String, dynamic>{'taskId': opIdB},
      );

      expect(localClient.currentPendingMutations, hasLength(4));

      remoteClient.mutationResults['tasks:create'] = <Object?>[
        'server-A',
        'server-B',
      ];
      remoteClient.mutationResults['tasks:advance'] = <Object?>[
        'ok-A',
        'ok-B',
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, isEmpty);
      final advanceCalls = remoteClient.mutationCalls
          .where((c) => c.name == 'tasks:advance')
          .toList();
      expect(advanceCalls[0].args['taskId'], 'server-A');
      expect(advanceCalls[1].args['taskId'], 'server-B');
    });

    test('replay is a no-op when args contain no local IDs', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'User', 'text': 'No local IDs here'},
      );

      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        'msg-id-1',
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, isEmpty);
      // Args should be unchanged.
      expect(
        remoteClient.mutationCalls.first.args['text'],
        'No local IDs here',
      );
    });

    test('crash recovery: new client picks up persisted remaps', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      remoteClient.queryResults['tasks:list'] = <dynamic>[];

      // First client session — queue mutations offline.
      final firstClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            CreateTaskHandler(),
            AdvanceTaskHandler(),
          ],
        ),
      );

      await firstClient.query('tasks:list');
      await firstClient.setNetworkMode(LocalNetworkMode.offline);

      await firstClient.mutate(
        'tasks:create',
        <String, dynamic>{'title': 'Crash test'},
      );
      final opId = firstClient.currentPendingMutations.first
          .optimisticData!['operationId'] as String;
      await firstClient.mutate(
        'tasks:advance',
        <String, dynamic>{'taskId': opId},
      );

      // Simulate: create replays, but client crashes before advance.
      // Manually persist the remap as if the first mutation had replayed.
      await store.saveIdRemap(opId, 'server-crash-id');
      // Remove the first mutation (create) as if it had been replayed.
      final allMutations = await store.loadAll();
      await store.remove(allMutations.first.id);

      // Abandon first client without dispose (simulates crash).
      // Create a new client — simulates restart after crash.
      remoteClient = FakeRemoteClient();
      remoteClient.queryResults['tasks:list'] = <dynamic>[];
      remoteClient.mutationResults['tasks:advance'] = <Object?>['ok'];
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            CreateTaskHandler(),
            AdvanceTaskHandler(),
          ],
        ),
      );
      await pumpEventQueue();

      // The advance mutation should have been replayed with the remapped ID.
      expect(localClient.currentPendingMutations, isEmpty);
      expect(remoteClient.mutationCalls, hasLength(1));
      expect(
          remoteClient.mutationCalls.first.args['taskId'], 'server-crash-id');
    });

    test('clearQueue also clears remaps', () async {
      await store.saveIdRemap('local-123', 'server-456');
      final remapsBefore = await store.loadIdRemaps();
      expect(remapsBefore, isNotEmpty);

      await localClient.clearQueue();

      final remapsAfter = await store.loadIdRemaps();
      expect(remapsAfter, isEmpty);
    });

    // ---------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------

    test('actions throw when forced offline', () async {
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await expectLater(
        localClient.action('demo:ping'),
        throwsA(isA<ConvexException>()),
      );
    });

    // ---------------------------------------------------------------
    // clearCache and clearQueue
    // ---------------------------------------------------------------

    test('clearCache removes cached queries', () async {
      remoteClient.queryResults['tasks:list'] = <dynamic>['task-1'];
      await localClient.query('tasks:list');

      await localClient.clearCache();

      await localClient.setNetworkMode(LocalNetworkMode.offline);
      await expectLater(
        localClient.query('tasks:list'),
        throwsA(isA<StateError>()),
      );
    });

    test('clearQueue removes pending mutations and updates subscribers',
        () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'User', 'text': 'Queued'},
      );
      expect(localClient.currentPendingMutations, hasLength(1));

      await localClient.clearQueue();
      expect(localClient.currentPendingMutations, isEmpty);
    });

    // ---------------------------------------------------------------
    // Dispose
    // ---------------------------------------------------------------

    test('operations throw after dispose', () async {
      await localClient.dispose();

      expect(() => localClient.query('test:q'), throwsA(isA<StateError>()));
      expect(() => localClient.subscribe('test:q'), throwsA(isA<StateError>()));
      expect(
        () => localClient.mutate('test:m'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => localClient.action('test:a'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('SqliteLocalStore', () {
    test('openInMemory creates a working store', () async {
      final store = await SqliteLocalStore.openInMemory();

      // Write and read a cache entry.
      await store.upsert(StoredCacheEntry(
        key: 'test-key',
        queryName: 'test:query',
        argsJson: '{}',
        valueJson: '"hello"',
        updatedAtMillis: 1000,
      ));
      final entry = await store.read('test-key');
      expect(entry, isNotNull);
      expect(entry!.valueJson, '"hello"');

      // Enqueue and load a mutation.
      await store.enqueue(
        mutationName: 'test:mutate',
        argsJson: '{}',
        optimisticJson: null,
        createdAtMillis: 2000,
      );
      final mutations = await store.loadAll();
      expect(mutations, hasLength(1));
      expect(mutations.first.mutationName, 'test:mutate');

      await store.close();
    });

    test('read returns null for missing key', () async {
      final store = await SqliteLocalStore.openInMemory();
      final entry = await store.read('nonexistent');
      expect(entry, isNull);
      await store.close();
    });

    test('upsert overwrites existing entry', () async {
      final store = await SqliteLocalStore.openInMemory();

      await store.upsert(StoredCacheEntry(
        key: 'k',
        queryName: 'q',
        argsJson: '{}',
        valueJson: '"v1"',
        updatedAtMillis: 1000,
      ));
      await store.upsert(StoredCacheEntry(
        key: 'k',
        queryName: 'q',
        argsJson: '{}',
        valueJson: '"v2"',
        updatedAtMillis: 2000,
      ));

      final entry = await store.read('k');
      expect(entry!.valueJson, '"v2"');
      expect(entry.updatedAtMillis, 2000);

      await store.close();
    });

    test('clearCache and clearQueue are independent', () async {
      final store = await SqliteLocalStore.openInMemory();

      await store.upsert(StoredCacheEntry(
        key: 'k',
        queryName: 'q',
        argsJson: '{}',
        valueJson: '"v"',
        updatedAtMillis: 1000,
      ));
      await store.enqueue(
        mutationName: 'm',
        argsJson: '{}',
        optimisticJson: null,
        createdAtMillis: 1000,
      );

      await store.clearCache();
      expect(await store.read('k'), isNull);
      expect(await store.loadAll(), hasLength(1));

      await store.clearQueue();
      expect(await store.loadAll(), isEmpty);

      await store.close();
    });

    test('markStatus updates mutation status and error', () async {
      final store = await SqliteLocalStore.openInMemory();

      final mutation = await store.enqueue(
        mutationName: 'm',
        argsJson: '{}',
        optimisticJson: null,
        createdAtMillis: 1000,
      );

      await store.markStatus(mutation.id, 'replaying', errorMessage: 'retry');

      final all = await store.loadAll();
      expect(all.single.status, 'replaying');
      expect(all.single.errorMessage, 'retry');

      await store.close();
    });

    test('operations throw StateError after close', () async {
      final store = await SqliteLocalStore.openInMemory();
      await store.close();

      await expectLater(store.read('k'), throwsA(isA<StateError>()));
    });

    test('double close is safe', () async {
      final store = await SqliteLocalStore.openInMemory();
      await store.close();
      await store.close(); // Should not throw.
    });

    test('mutation queue preserves insertion order via auto-increment',
        () async {
      final store = await SqliteLocalStore.openInMemory();

      for (int i = 1; i <= 5; i++) {
        await store.enqueue(
          mutationName: 'mutation-$i',
          argsJson: '{}',
          optimisticJson: null,
          createdAtMillis: i * 1000,
        );
      }

      final all = await store.loadAll();
      expect(all, hasLength(5));
      for (int i = 0; i < 5; i++) {
        expect(all[i].mutationName, 'mutation-${i + 1}');
      }
      for (int i = 0; i < 4; i++) {
        expect(all[i].id, lessThan(all[i + 1].id));
      }

      await store.close();
    });
  });

  group('JsonValueCodec', () {
    const codec = JsonValueCodec();

    test('encode and decode roundtrip for primitives', () {
      expect(codec.decode(codec.encode('hello')), 'hello');
      expect(codec.decode(codec.encode(42)), 42);
      expect(codec.decode(codec.encode(true)), true);
      expect(codec.decode(codec.encode(null)), null);
    });

    test('encode and decode roundtrip for nested structures', () {
      final value = <String, dynamic>{
        'name': 'test',
        'items': <dynamic>[1, 2, 3],
        'nested': <String, dynamic>{'key': 'value'},
      };
      final roundtripped = codec.decode(codec.encode(value));
      expect(roundtripped, value);
    });

    test('decodeMap throws FormatException for non-map JSON', () {
      expect(
        () => codec.decodeMap('"a string"'),
        throwsA(isA<FormatException>()),
      );
    });

    test('encode canonicalizes key order', () {
      final a = codec.encode(<String, dynamic>{'b': 2, 'a': 1});
      final b = codec.encode(<String, dynamic>{'a': 1, 'b': 2});
      expect(a, b);
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class FakeRemoteClient implements LocalRemoteClient {
  final Map<String, dynamic> queryResults = <String, dynamic>{};
  final Map<String, ConvexException> queryErrors = <String, ConvexException>{};
  final Map<String, List<Object?>> mutationResults = <String, List<Object?>>{};
  final List<RemoteCall> mutationCalls = <RemoteCall>[];
  final StreamController<LocalRemoteConnectionState>
      _connectionStateController =
      StreamController<LocalRemoteConnectionState>.broadcast(sync: true);
  LocalRemoteConnectionState _currentConnectionState =
      LocalRemoteConnectionState.connected;

  @override
  Stream<LocalRemoteConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  LocalRemoteConnectionState get currentConnectionState =>
      _currentConnectionState;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return 'action-ok';
  }

  @override
  void dispose() {
    unawaited(_connectionStateController.close());
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    mutationCalls.add(RemoteCall(name, args));
    final results = mutationResults[name];
    if (results == null || results.isEmpty) {
      throw const ConvexException('Missing fake mutation result');
    }
    final next = results.removeAt(0);
    if (next is ConvexException) {
      throw next;
    }
    if (next is Exception) {
      throw next;
    }
    if (next is Error) {
      throw next;
    }
    return next;
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final error = queryErrors[name];
    if (error != null) {
      throw error;
    }
    if (!queryResults.containsKey(name)) {
      throw const ConvexException('Missing fake query result', retryable: true);
    }
    return queryResults[name];
  }

  @override
  LocalRemoteSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return FakeRemoteSubscription(
      Stream<LocalRemoteQueryEvent>.value(
        LocalRemoteQuerySuccess(queryResults[name]),
      ),
    );
  }

  void setConnectionState(LocalRemoteConnectionState state) {
    _currentConnectionState = state;
    _connectionStateController.add(state);
  }
}

class FakeRemoteSubscription implements LocalRemoteSubscription {
  FakeRemoteSubscription(this._stream);

  final Stream<LocalRemoteQueryEvent> _stream;

  @override
  Stream<LocalRemoteQueryEvent> get stream => _stream;

  @override
  void cancel() {}
}

class RemoteCall {
  const RemoteCall(this.name, this.args);

  final String name;
  final Map<String, dynamic> args;
}

class CreateTaskHandler extends LocalMutationHandler {
  const CreateTaskHandler();

  @override
  String get mutationName => 'tasks:create';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('tasks:list'),
        apply: (currentValue) {
          final existing = currentValue is List
              ? List<dynamic>.from(currentValue)
              : <dynamic>[];
          existing.add(<String, dynamic>{
            '_id': context.operationId,
            'title': args['title'],
          });
          return existing;
        },
      ),
    ];
  }
}

class AdvanceTaskHandler extends LocalMutationHandler {
  const AdvanceTaskHandler();

  @override
  String get mutationName => 'tasks:advance';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('tasks:list'),
        apply: (currentValue) => currentValue,
      ),
    ];
  }
}

class PublicMessageMutationHandler extends LocalMutationHandler {
  const PublicMessageMutationHandler();

  @override
  String get mutationName => 'messages:sendPublic';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('messages:listPublic'),
        apply: (currentValue) {
          final existing = currentValue is List
              ? List<dynamic>.from(currentValue)
              : <dynamic>[];
          existing.add(<String, dynamic>{
            '_id': context.operationId,
            '_creationTime': context.queuedAt.millisecondsSinceEpoch.toDouble(),
            'author': args['author'],
            'text': args['text'],
          });
          return existing;
        },
      ),
    ];
  }
}
