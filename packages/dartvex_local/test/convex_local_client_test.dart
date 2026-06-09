import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:dartvex_local/src/storage/sqlite_local_store_native.dart'
    as native;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  group('PendingMutation', () {
    test('copyWith can preserve, replace, and clear error messages', () {
      final mutation = PendingMutation(
        id: 1,
        mutationName: 'messages:send',
        args: const <String, dynamic>{'body': 'hello'},
        createdAt: DateTime.utc(2026),
        status: PendingMutationStatus.pending,
        errorMessage: 'retry later',
      );

      expect(mutation.copyWith().errorMessage, 'retry later');
      expect(
        mutation.copyWith(errorMessage: 'offline').errorMessage,
        'offline',
      );
      expect(mutation.copyWith(clearErrorMessage: true).errorMessage, isNull);
      expect(
        () =>
            mutation.copyWith(errorMessage: 'offline', clearErrorMessage: true),
        throwsArgumentError,
      );
    });
  });

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
      remoteClient.dispose();
    });

    test('synchronous cancel while delivering an event does not throw '
        'ConcurrentModificationError', () async {
      // Two subscribers share one query state; delivering an event fans out
      // over that shared subscriber set. Cancelling one subscriber from its
      // own (synchronous) listener mutates the set mid-iteration, which
      // previously threw a ConcurrentModificationError.
      final feed = StreamController<LocalRemoteQueryEvent>.broadcast();
      addTearDown(feed.close);
      remoteClient.subscriptionStreams['messages:listPublic'] = feed.stream;

      final received = <String>[];
      final first = localClient.subscribe('messages:listPublic');
      final second = localClient.subscribe('messages:listPublic');

      first.stream.listen((event) {
        received.add('first');
        first.cancel();
      });
      second.stream.listen((event) {
        received.add('second');
      });

      // Let both subscriptions wire up their shared remote feed.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      feed.add(const LocalRemoteQuerySuccess(<dynamic>[]));

      // Allow the cache write + fan-out to run. With the bug, the fan-out
      // raised an unhandled ConcurrentModificationError and never reached the
      // second subscriber.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, containsAll(<String>['first', 'second']));
    });

    test('detached cache seed errors are logged instead of escaping', () async {
      await localClient.dispose();
      final queueStore = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      final logs = <DartvexLogEvent>[];
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: const ThrowingCacheStorage(),
          queueStorage: queueStore,
          logLevel: DartvexLogLevel.debug,
          logger: logs.add,
        ),
      );

      final subscription = localClient.subscribe('messages:listPublic');
      addTearDown(subscription.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(logs.map((event) => event.tag), contains('local.seed:error'));
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
      remoteClient.queryErrors['tasks:list'] = const ConvexException(
        'Validation failed',
        retryable: false,
      );

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

    test('subscribe ignores stale cache seed after remote event', () async {
      await localClient.dispose();
      final cacheStore = await SqliteLocalStore.openInMemory();
      final queueStore = await SqliteLocalStore.openInMemory();
      await QueryCache(
        storage: cacheStore,
        codec: const JsonValueCodec(),
      ).write(
        name: 'tasks:list',
        args: const <String, dynamic>{},
        value: ['stale'],
      );
      final readGate = Completer<void>();
      final delayedCache = DelayedReadCacheStorage(
        cacheStore,
        delayAfterRead: readGate.future,
      );
      remoteClient = FakeRemoteClient();
      remoteClient.subscriptionStreams['tasks:list'] =
          Stream<LocalRemoteQueryEvent>.value(
            const LocalRemoteQuerySuccess(<dynamic>['fresh']),
          );
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: delayedCache,
          queueStorage: queueStore,
        ),
      );

      final events = <LocalQueryEvent>[];
      final sub = localClient.subscribe('tasks:list');
      final listener = sub.stream.listen(events.add);
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single, isA<LocalQuerySuccess>());
      final remoteEvent = events.single as LocalQuerySuccess;
      expect(remoteEvent.source, LocalQuerySource.remote);
      expect(remoteEvent.value, <dynamic>['fresh']);

      readGate.complete();
      await pumpEventQueue();

      expect(events, hasLength(1));

      await listener.cancel();
      sub.cancel();
    });

    test('subscribe ignores remote loading while seeding from cache', () async {
      await localClient.dispose();
      final cacheStore = await SqliteLocalStore.openInMemory();
      final queueStore = await SqliteLocalStore.openInMemory();
      await QueryCache(
        storage: cacheStore,
        codec: const JsonValueCodec(),
      ).write(
        name: 'tasks:list',
        args: const <String, dynamic>{},
        value: ['cached'],
      );
      remoteClient = FakeRemoteClient();
      remoteClient.subscriptionStreams['tasks:list'] =
          Stream<LocalRemoteQueryEvent>.value(
            const LocalRemoteQueryLoading(hasPendingWrites: true),
          );
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: cacheStore,
          queueStorage: queueStore,
        ),
      );

      final events = <LocalQueryEvent>[];
      final sub = localClient.subscribe('tasks:list');
      final listener = sub.stream.listen(events.add);
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single, isA<LocalQuerySuccess>());
      final cachedEvent = events.single as LocalQuerySuccess;
      expect(cachedEvent.source, LocalQuerySource.cache);
      expect(cachedEvent.value, <dynamic>['cached']);

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
      expect((events.first as LocalQueryError).source, LocalQuerySource.cache);

      await listener.cancel();
      sub.cancel();
    });

    // ---------------------------------------------------------------
    // Queueing and replay behavior
    // ---------------------------------------------------------------

    test(
      'queues offline mutations and applies optimistic cache updates',
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
      },
    );

    test('queues auto-mode mutations immediately while disconnected', () async {
      remoteClient.setConnectionState(LocalRemoteConnectionState.disconnected);

      final result = await localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'Local', 'text': 'Queued'},
      );

      expect(result, isA<LocalMutationQueued>());
      expect(remoteClient.mutationCalls, isEmpty);
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

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'First',
      });
      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'B',
        'text': 'Second',
      });

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

    test('serializes concurrent online mutations to preserve call order', () async {
      // Online + connected + empty queue: the first mutation takes the direct
      // "send to remote" fast path. Gate its remote call so it stays in flight
      // while a second mutation is fired concurrently.
      final firstRemote = Completer<Object?>();
      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        firstRemote.future,
        const ConvexException('drop', retryable: true),
      ];

      final first = localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'First',
      });
      final second = localClient.mutate(
        'messages:sendPublic',
        <String, dynamic>{'author': 'B', 'text': 'Second'},
      );
      await pumpEventQueue();

      // FIFO serialization: the second mutation has not started yet, so only the
      // first has reached the remote. Without serialization both would race the
      // empty-queue fast path and the second could enqueue ahead of the first.
      expect(remoteClient.mutationCalls, hasLength(1));
      expect(remoteClient.mutationCalls.single.args['text'], 'First');

      // Fail the first so it falls back to the queue; the second then sees a
      // non-empty queue and enqueues behind it, preserving call order.
      firstRemote.completeError(const ConvexException('drop', retryable: true));
      await first;
      await second;

      expect(
        localClient.currentPendingMutations
            .map((mutation) => mutation.args['text'])
            .toList(),
        <String>['First', 'Second'],
      );
    });

    test('does not replay queued mutations until remote connects', () async {
      await localClient.setNetworkMode(LocalNetworkMode.offline);
      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'Deferred',
      });

      remoteClient
        ..setConnectionState(LocalRemoteConnectionState.disconnected)
        ..mutationResults['messages:sendPublic'] = <Object?>['server-id-1'];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(remoteClient.mutationCalls, isEmpty);
      expect(localClient.currentPendingMutations, hasLength(1));

      remoteClient.setConnectionState(LocalRemoteConnectionState.connected);
      await localClient.pendingMutations
          .firstWhere((list) => list.isEmpty)
          .timeout(const Duration(seconds: 2));

      expect(remoteClient.mutationCalls, hasLength(1));
      expect(localClient.currentPendingMutations, isEmpty);
    });

    test('refresh timeout cancels one-shot remote subscription', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          refreshQueryTimeout: const Duration(milliseconds: 1),
          mutationHandlers: const <LocalMutationHandler>[
            PublicMessageMutationHandler(),
          ],
        ),
      );

      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);
      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'queued',
      });

      final refreshStream = StreamController<LocalRemoteQueryEvent>.broadcast();
      remoteClient.subscriptionStreams['messages:listPublic'] =
          refreshStream.stream;
      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        'server-id-1',
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(remoteClient.subscriptionCancelCounts['messages:listPublic'], 1);
      await refreshStream.close();
    });

    test('replay stops and retains queue on retryable error', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'First',
      });
      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'B',
        'text': 'Second',
      });

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

    test(
      'queues auto-mode mutations behind a non-empty replay queue',
      () async {
        await localClient.setNetworkMode(LocalNetworkMode.offline);
        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'A',
          'text': 'OLDER',
        });

        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          const ConvexException('Server busy', retryable: true),
          'server-id-old',
          'server-id-new',
        ];

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, hasLength(1));
        expect(remoteClient.mutationCalls, hasLength(1));
        expect(remoteClient.mutationCalls.single.args['text'], 'OLDER');

        final newer = await localClient.mutate(
          'messages:sendPublic',
          <String, dynamic>{'author': 'B', 'text': 'NEWER'},
        );

        expect(newer, isA<LocalMutationQueued>());
        expect(localClient.currentPendingMutations, hasLength(2));
        expect(
          remoteClient.mutationCalls.map((call) => call.args['text']).toList(),
          <String>['OLDER'],
        );
      },
    );

    test('replay retries automatically after retryable error', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'retry-test',
      });

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

    test(
      'dispose cancels in-flight replay without closed store writes',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'A',
          'text': 'dispose-mid-replay',
        });

        final replayResult = Completer<Object?>();
        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          replayResult.future,
        ];

        final goOnline = localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();
        expect(remoteClient.mutationCalls, hasLength(1));

        await localClient.dispose();
        replayResult.complete('server-id-after-dispose');

        await expectLater(goOnline, completes);
      },
    );

    test(
      'replay drops mutation and fires onConflict on non-retryable error',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'A',
          'text': 'WillFail',
        });
        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'B',
          'text': 'ShouldStillReplay',
        });

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
      },
    );

    test(
      'replay rollback restores cache when a failed mutation refresh fails',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'A',
          'text': 'WillFail',
        });

        final optimistic =
            await localClient.query('messages:listPublic') as List<dynamic>;
        expect(optimistic, hasLength(1));
        expect(optimistic.single['text'], 'WillFail');

        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          const ConvexException('Validation failed', retryable: false),
        ];
        remoteClient.subscriptionStreams['messages:listPublic'] =
            Stream<LocalRemoteQueryEvent>.value(
              const LocalRemoteQueryError(
                ConvexException('Refresh failed', retryable: false),
              ),
            );

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);

        await localClient.setNetworkMode(LocalNetworkMode.offline);
        final restored =
            await localClient.query('messages:listPublic') as List<dynamic>;
        expect(restored, isEmpty);
      },
    );

    test('replay rollback reapplies later pending optimistic writes', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'WillFail',
      });
      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'B',
        'text': 'ShouldRemainOptimistic',
      });

      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        const ConvexException('Validation failed', retryable: false),
        const ConvexException('Server busy', retryable: true),
      ];
      remoteClient.subscriptionStreams['messages:listPublic'] =
          Stream<LocalRemoteQueryEvent>.value(
            const LocalRemoteQueryError(
              ConvexException('Refresh failed', retryable: true),
            ),
          );

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, hasLength(1));
      expect(
        localClient.currentPendingMutations.single.args['text'],
        'ShouldRemainOptimistic',
      );

      await localClient.setNetworkMode(LocalNetworkMode.offline);
      final restored =
          await localClient.query('messages:listPublic') as List<dynamic>;

      expect(restored.map((message) => message['text']).toList(), <String>[
        'ShouldRemainOptimistic',
      ]);
    });

    test(
      'two consecutive dropped mutations do not resurface the first when the '
      'post-drop refresh fails',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'A',
          'text': 'FirstFail',
        });
        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'B',
          'text': 'SecondFail',
        });

        // Both queued mutations are rejected non-retryably, so both are
        // dropped in the same replay pass.
        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          const ConvexException('Validation failed', retryable: false),
          const ConvexException('Validation failed', retryable: false),
        ];
        // The post-drop refresh of the shared target keeps failing (a
        // re-subscribable error stream), so a surviving mutation's rollback
        // baseline is never rebased from the server between the two drops.
        remoteClient.subscriptionStreams['messages:listPublic'] =
            Stream<LocalRemoteQueryEvent>.multi((controller) {
              controller.addError(
                const ConvexException('Refresh failed', retryable: false),
              );
              controller.close();
            });

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);

        await localClient.setNetworkMode(LocalNetworkMode.offline);
        final restored =
            await localClient.query('messages:listPublic') as List<dynamic>;
        // Dropping the second mutation must not restore a baseline that still
        // contains the first, already-dropped mutation.
        expect(restored, isEmpty);
      },
    );

    test('remote snapshots preserve pending optimistic writes', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');

      final events = <LocalQueryEvent>[];
      final sub = localClient.subscribe('messages:listPublic');
      final listener = sub.stream.listen(events.add);
      await pumpEventQueue();

      await localClient.setNetworkMode(LocalNetworkMode.offline);
      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'Local',
        'text': 'Pending',
      });

      remoteClient.queryResults['messages:listPublic'] = <dynamic>[
        <String, dynamic>{
          '_id': 'server-1',
          '_creationTime': 1,
          'author': 'Server',
          'text': 'Server',
        },
      ];
      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        const ConvexException('Server busy', retryable: true),
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      final latest = events.whereType<LocalQuerySuccess>().last;
      expect(latest.hasPendingWrites, isTrue);
      expect(latest.value.map((message) => message['text']).toList(), <String>[
        'Server',
        'Pending',
      ]);

      await listener.cancel();
      sub.cancel();
    });

    test('online query snapshots preserve pending optimistic writes', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'Local',
        'text': 'Pending',
      });

      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        const ConvexException('Server busy', retryable: true),
      ];
      await localClient.setNetworkMode(LocalNetworkMode.auto);

      remoteClient.queryResults['messages:listPublic'] = <dynamic>[
        <String, dynamic>{
          '_id': 'server-1',
          '_creationTime': 1,
          'author': 'Server',
          'text': 'Server',
        },
      ];

      final value = await localClient.query('messages:listPublic');
      expect((value as List<dynamic>).map((message) => message['text']), [
        'Server',
        'Pending',
      ]);
    });

    test(
      'remote snapshots rebase rollback before failed pending mutations',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        final sub = localClient.subscribe('messages:listPublic');
        final listener = sub.stream.listen((_) {});
        await pumpEventQueue();

        await localClient.setNetworkMode(LocalNetworkMode.offline);
        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'A',
          'text': 'WillFail',
        });
        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'B',
          'text': 'ShouldRemainOptimistic',
        });

        remoteClient.queryResults['messages:listPublic'] = <dynamic>[
          <String, dynamic>{
            '_id': 'server-1',
            '_creationTime': 1,
            'author': 'Server',
            'text': 'Server',
          },
        ];
        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          const ConvexException('Validation failed', retryable: false),
          const ConvexException('Server busy', retryable: true),
        ];

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, hasLength(1));
        expect(
          localClient.currentPendingMutations.single.args['text'],
          'ShouldRemainOptimistic',
        );

        await localClient.setNetworkMode(LocalNetworkMode.offline);
        final restored =
            await localClient.query('messages:listPublic') as List<dynamic>;

        expect(restored.map((message) => message['text']).toList(), <String>[
          'Server',
          'ShouldRemainOptimistic',
        ]);

        await listener.cancel();
        sub.cancel();
      },
    );

    test(
      'replay rollback deletes optimistic-only cache through custom storage',
      () async {
        await localClient.dispose();
        store = await SqliteLocalStore.openInMemory();
        remoteClient = FakeRemoteClient();
        final cacheStorage = DelayedReadCacheStorage(
          store,
          delayAfterRead: Future<void>.value(),
        );
        localClient = await ConvexLocalClient.openWithRemote(
          remoteClient: remoteClient,
          config: LocalClientConfig(
            cacheStorage: cacheStorage,
            queueStorage: store,
            mutationHandlers: const <LocalMutationHandler>[
              PublicMessageMutationHandler(),
            ],
          ),
        );
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'A',
          'text': 'OptimisticOnly',
        });
        final optimistic =
            await localClient.query('messages:listPublic') as List<dynamic>;
        expect(optimistic.single['text'], 'OptimisticOnly');

        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          const ConvexException('Validation failed', retryable: false),
        ];
        remoteClient.subscriptionStreams['messages:listPublic'] =
            Stream<LocalRemoteQueryEvent>.value(
              const LocalRemoteQueryError(
                ConvexException('Refresh failed', retryable: false),
              ),
            );

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);
        expect(
          await store.read(
            const LocalQueryDescriptor('messages:listPublic').key,
          ),
          isNull,
        );
      },
    );

    test('onConflict exceptions do not stop replay cleanup', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'A',
        'text': 'WillFail',
      });

      localClient.onConflict = (_) => throw StateError('callback failed');
      remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
        const ConvexException('Validation failed', retryable: false),
      ];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, isEmpty);
    });

    test('multiple queued mutations preserve insertion order', () async {
      remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
      await localClient.query('messages:listPublic');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      for (int i = 1; i <= 5; i++) {
        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'User',
          'text': 'Message $i',
        });
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
      expect(localClient.currentConnectionState, LocalConnectionState.offline);

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      expect(localClient.currentNetworkMode, LocalNetworkMode.auto);

      await subscription.cancel();
      // Initial emit + offline + auto.
      expect(modes, contains(LocalNetworkMode.offline));
      expect(modes, contains(LocalNetworkMode.auto));
    });

    test('repeated offline toggles do not leak or duplicate events', () async {
      final connectionStates = <LocalConnectionState>[];
      final subscription = localClient.connectionState.listen(
        connectionStates.add,
      );

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

    test(
      'connection state reflects remote disconnection in auto mode',
      () async {
        remoteClient.setConnectionState(
          LocalRemoteConnectionState.disconnected,
        );
        await pumpEventQueue();

        expect(
          localClient.currentConnectionState,
          LocalConnectionState.offline,
        );

        remoteClient.setConnectionState(LocalRemoteConnectionState.connected);
        await pumpEventQueue();

        expect(localClient.currentConnectionState, LocalConnectionState.online);
      },
    );

    // ---------------------------------------------------------------
    // Mutation handlers and patches
    // ---------------------------------------------------------------

    test(
      'mutation without handler still queues but creates no patches',
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
      },
    );

    test('patch failure removes the queued mutation', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            ThrowingPatchMutationHandler(),
          ],
        ),
      );
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await expectLater(
        localClient.mutate('tasks:throwPatch', <String, dynamic>{}),
        throwsStateError,
      );

      expect(localClient.currentPendingMutations, isEmpty);
      expect(await store.loadAll(), isEmpty);
    });

    test('patch failure rolls back earlier cache writes', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            PartiallyThrowingPatchMutationHandler(),
          ],
        ),
      );
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await expectLater(
        localClient.mutate('tasks:partialThrowPatch', <String, dynamic>{}),
        throwsStateError,
      );

      expect(localClient.currentPendingMutations, isEmpty);
      expect(await store.loadAll(), isEmpty);
      expect(
        await store.read(const LocalQueryDescriptor('tasks:list').key),
        isNull,
      );
    });

    test('handler patch applies even when no cached query exists', () async {
      // No cache seeded — patch will get null as currentValue.
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'User',
        'text': 'First ever',
      });

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
      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'User',
        'text': 'Pending',
      });
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
      await localClient.mutate('tasks:create', <String, dynamic>{
        'title': 'Buy milk',
      });
      // Advance that task offline — uses the local operationId as taskId.
      final pending = localClient.currentPendingMutations;
      final createOpId = pending.first.optimisticData!['operationId'] as String;
      await localClient.mutate('tasks:advance', <String, dynamic>{
        'taskId': createOpId,
      });

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

    test('replay remaps local IDs from object create result', () async {
      remoteClient.queryResults['tasks:list'] = <dynamic>[];
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

      await localClient.mutate('tasks:create', <String, dynamic>{
        'title': 'Object result',
      });
      final createOpId =
          localClient
                  .currentPendingMutations
                  .first
                  .optimisticData!['operationId']
              as String;
      await localClient.mutate('tasks:advance', <String, dynamic>{
        'taskId': createOpId,
      });

      remoteClient.mutationResults['tasks:create'] = <Object?>[
        <String, dynamic>{'_id': 'server-task-object'},
      ];
      remoteClient.mutationResults['tasks:advance'] = <Object?>['ok'];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, isEmpty);
      expect(remoteClient.mutationCalls, hasLength(2));
      final advanceCall = remoteClient.mutationCalls[1];
      expect(advanceCall.name, 'tasks:advance');
      expect(advanceCall.args['taskId'], 'server-task-object');
    });

    test('replay remaps local IDs used as map keys', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      remoteClient.queryResults['tasks:list'] = <dynamic>[];
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[CreateTaskHandler()],
        ),
      );

      await localClient.query('tasks:list');
      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await localClient.mutate('tasks:create', <String, dynamic>{
        'title': 'Keyed',
      });
      final createOpId =
          localClient
                  .currentPendingMutations
                  .first
                  .optimisticData!['operationId']
              as String;
      // Use the freshly-created local operationId as a MAP KEY (not just a
      // value) in the next offline mutation's args.
      await localClient.mutate('scores:set', <String, dynamic>{
        'byTask': <String, dynamic>{createOpId: 10},
      });

      remoteClient.mutationResults['tasks:create'] = <Object?>[
        'server-task-keyed',
      ];
      remoteClient.mutationResults['scores:set'] = <Object?>['ok'];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, isEmpty);
      expect(remoteClient.mutationCalls, hasLength(2));
      final setCall = remoteClient.mutationCalls[1];
      expect(setCall.name, 'scores:set');
      final byTask = (setCall.args['byTask'] as Map).cast<String, dynamic>();
      // The local-ID key must be remapped to the server ID, not left stale.
      expect(byTask.containsKey('server-task-keyed'), isTrue);
      expect(byTask.containsKey(createOpId), isFalse);
      expect(byTask['server-task-keyed'], 10);
    });

    test(
      'replay drops map-key remaps that collide with existing keys',
      () async {
        await localClient.dispose();
        store = await SqliteLocalStore.openInMemory();
        remoteClient = FakeRemoteClient();
        remoteClient.queryResults['tasks:list'] = <dynamic>[];
        localClient = await ConvexLocalClient.openWithRemote(
          remoteClient: remoteClient,
          config: LocalClientConfig(
            cacheStorage: store,
            queueStorage: store,
            mutationHandlers: const <LocalMutationHandler>[CreateTaskHandler()],
          ),
        );

        await localClient.query('tasks:list');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('tasks:create', <String, dynamic>{
          'title': 'Key collision',
        });
        final createOpId =
            localClient
                    .currentPendingMutations
                    .first
                    .optimisticData!['operationId']
                as String;
        await localClient.mutate('scores:set', <String, dynamic>{
          'byTask': <String, dynamic>{'server-task-keyed': 99, createOpId: 10},
        });

        final conflicts = <LocalMutationConflict>[];
        localClient.onConflict = conflicts.add;
        remoteClient.mutationResults['tasks:create'] = <Object?>[
          'server-task-keyed',
        ];
        remoteClient.mutationResults['scores:set'] = <Object?>['ok'];

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);
        expect(remoteClient.mutationCalls.map((call) => call.name), <String>[
          'tasks:create',
        ]);
        expect(conflicts, hasLength(1));
        expect(conflicts.single.mutationName, 'scores:set');
        expect(
          conflicts.single.error.toString(),
          contains('ID remap collision'),
        );
      },
    );

    test('replay drops dependents when producer local ID fails', () async {
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

      await localClient.mutate('tasks:create', <String, dynamic>{
        'title': 'Will fail',
      });
      final createOpId =
          localClient
                  .currentPendingMutations
                  .first
                  .optimisticData!['operationId']
              as String;
      await localClient.mutate('tasks:advance', <String, dynamic>{
        'taskId': createOpId,
      });

      final conflicts = <LocalMutationConflict>[];
      localClient.onConflict = conflicts.add;
      remoteClient.mutationResults['tasks:create'] = <Object?>[
        const ConvexException('Validation failed', retryable: false),
      ];
      remoteClient.mutationResults['tasks:advance'] = <Object?>['ok'];

      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await pumpEventQueue();

      expect(localClient.currentPendingMutations, isEmpty);
      expect(remoteClient.mutationCalls.map((call) => call.name), <String>[
        'tasks:create',
      ]);
      expect(conflicts.map((conflict) => conflict.mutationName), <String>[
        'tasks:create',
        'tasks:advance',
      ]);
      expect(conflicts.last.error.toString(), contains('unresolved local ID'));
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
      await localClient.mutate('tasks:create', <String, dynamic>{
        'title': 'Task A',
      });
      final opIdA =
          localClient.currentPendingMutations[0].optimisticData!['operationId']
              as String;

      await localClient.mutate('tasks:create', <String, dynamic>{
        'title': 'Task B',
      });
      final opIdB =
          localClient.currentPendingMutations[1].optimisticData!['operationId']
              as String;

      // Advance both using their local IDs.
      await localClient.mutate('tasks:advance', <String, dynamic>{
        'taskId': opIdA,
      });
      await localClient.mutate('tasks:advance', <String, dynamic>{
        'taskId': opIdB,
      });

      expect(localClient.currentPendingMutations, hasLength(4));

      remoteClient.mutationResults['tasks:create'] = <Object?>[
        'server-A',
        'server-B',
      ];
      remoteClient.mutationResults['tasks:advance'] = <Object?>['ok-A', 'ok-B'];

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

      await localClient.mutate('messages:sendPublic', <String, dynamic>{
        'author': 'User',
        'text': 'No local IDs here',
      });

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

    test(
      'replay does not treat local-prefixed user strings as local IDs',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'User',
          'text': 'local-cache',
        });

        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          'msg-id-2',
        ];

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);
        expect(remoteClient.mutationCalls.first.args['text'], 'local-cache');
      },
    );

    test(
      'replay does not treat generated-shaped user strings as local IDs',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'User',
          'text': 'local-123-456',
          'nested': <String, dynamic>{
            'local-987-654': <String>['local-222-333'],
          },
        });

        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          'msg-id-3',
        ];

        await localClient.setNetworkMode(LocalNetworkMode.auto);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);
        final replayedArgs = remoteClient.mutationCalls.first.args;
        expect(replayedArgs['text'], 'local-123-456');
        expect(
          (replayedArgs['nested'] as Map).cast<String, dynamic>(),
          <String, dynamic>{
            'local-987-654': <String>['local-222-333'],
          },
        );
      },
    );

    test(
      'replay does not treat future operation IDs as current dependencies',
      () async {
        await localClient.dispose();
        store = await SqliteLocalStore.openInMemory();
        const codec = JsonValueCodec();
        const futureOperationId = 'local-200-2';
        await store.enqueue(
          mutationName: 'messages:sendPublic',
          argsJson: codec.encode(<String, dynamic>{
            'author': 'User',
            'text': futureOperationId,
          }),
          optimisticJson: null,
          createdAtMillis: 1,
        );
        await store.enqueue(
          mutationName: 'tasks:create',
          argsJson: codec.encode(<String, dynamic>{'title': 'Future'}),
          optimisticJson: codec.encode(<String, dynamic>{
            'operationId': futureOperationId,
            'targets': <dynamic>[],
            'rollback': <dynamic>[],
          }),
          createdAtMillis: 2,
        );

        remoteClient = FakeRemoteClient();
        remoteClient.mutationResults['messages:sendPublic'] = <Object?>[
          'msg-id-4',
        ];
        remoteClient.mutationResults['tasks:create'] = <Object?>[
          'server-task-future',
        ];
        localClient = await ConvexLocalClient.openWithRemote(
          remoteClient: remoteClient,
          config: LocalClientConfig(cacheStorage: store, queueStorage: store),
        );

        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);
        expect(remoteClient.mutationCalls, hasLength(2));
        expect(
          remoteClient.mutationCalls.first.args['text'],
          futureOperationId,
        );
      },
    );

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

      await firstClient.mutate('tasks:create', <String, dynamic>{
        'title': 'Crash test',
      });
      final opId =
          firstClient
                  .currentPendingMutations
                  .first
                  .optimisticData!['operationId']
              as String;
      await firstClient.mutate('tasks:advance', <String, dynamic>{
        'taskId': opId,
      });

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
        remoteClient.mutationCalls.first.args['taskId'],
        'server-crash-id',
      );
    });

    test(
      'crash recovery: new client drops dependents of failed local IDs',
      () async {
        await localClient.dispose();
        store = await SqliteLocalStore.openInMemory();
        remoteClient = FakeRemoteClient();
        remoteClient.queryResults['tasks:list'] = <dynamic>[];

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

        await firstClient.mutate('tasks:create', <String, dynamic>{
          'title': 'Failed before crash',
        });
        final opId =
            firstClient
                    .currentPendingMutations
                    .first
                    .optimisticData!['operationId']
                as String;
        await firstClient.mutate('tasks:advance', <String, dynamic>{
          'taskId': opId,
        });

        // Simulate: create failed and was removed, then the process crashed before
        // the dependent mutation was processed. The failed local ID tombstone must
        // survive the restart so the dependent is dropped instead of replayed.
        await store.saveFailedLocalId(opId);
        final allMutations = await store.loadAll();
        await store.remove(allMutations.first.id);

        remoteClient = FakeRemoteClient();
        remoteClient
          ..setConnectionState(LocalRemoteConnectionState.disconnected)
          ..queryResults['tasks:list'] = <dynamic>[]
          ..mutationResults['tasks:advance'] = <Object?>['ok'];
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
        final conflicts = <LocalMutationConflict>[];
        localClient.onConflict = conflicts.add;

        remoteClient.setConnectionState(LocalRemoteConnectionState.connected);
        await pumpEventQueue();

        expect(localClient.currentPendingMutations, isEmpty);
        expect(remoteClient.mutationCalls, isEmpty);
        expect(conflicts, hasLength(1));
        expect(conflicts.single.mutationName, 'tasks:advance');
        expect(
          conflicts.single.error.toString(),
          contains('unresolved local ID'),
        );
        expect(await store.loadFailedLocalIds(), isEmpty);
      },
    );

    test('clearQueue also clears remaps', () async {
      await store.saveIdRemap('local-123', 'server-456');
      await store.saveFailedLocalId('local-789-101');
      final remapsBefore = await store.loadIdRemaps();
      final failedIdsBefore = await store.loadFailedLocalIds();
      expect(remapsBefore, isNotEmpty);
      expect(failedIdsBefore, isNotEmpty);

      await localClient.clearQueue();

      final remapsAfter = await store.loadIdRemaps();
      final failedIdsAfter = await store.loadFailedLocalIds();
      expect(remapsAfter, isEmpty);
      expect(failedIdsAfter, isEmpty);
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

    test('offline query ignores expired cache entries', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          queryCachePolicy: const QueryCachePolicy(
            maxEntryAge: Duration(minutes: 5),
          ),
        ),
      );

      await store.upsert(
        StoredCacheEntry(
          key: LocalQueryDescriptor('tasks:list').key,
          queryName: 'tasks:list',
          argsJson: '{}',
          valueJson: '["expired-task"]',
          updatedAtMillis: DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        ),
      );

      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await expectLater(
        localClient.query('tasks:list'),
        throwsA(isA<StateError>()),
      );
      expect(await store.read(LocalQueryDescriptor('tasks:list').key), isNull);
    });

    test('cache policy prunes least recently written entries', () async {
      await localClient.dispose();
      store = await SqliteLocalStore.openInMemory();
      remoteClient = FakeRemoteClient();
      localClient = await ConvexLocalClient.openWithRemote(
        remoteClient: remoteClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          queryCachePolicy: const QueryCachePolicy(maxEntries: 2),
        ),
      );

      remoteClient.queryResults['tasks:first'] = 'first';
      remoteClient.queryResults['tasks:second'] = 'second';
      remoteClient.queryResults['tasks:third'] = 'third';

      await localClient.query('tasks:first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await localClient.query('tasks:second');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await localClient.query('tasks:third');

      await localClient.setNetworkMode(LocalNetworkMode.offline);

      await expectLater(
        localClient.query('tasks:first'),
        throwsA(isA<StateError>()),
      );
      expect(await localClient.query('tasks:second'), 'second');
      expect(await localClient.query('tasks:third'), 'third');
    });

    test(
      'clearQueue removes pending mutations and updates subscribers',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'User',
          'text': 'Queued',
        });
        expect(localClient.currentPendingMutations, hasLength(1));

        await localClient.clearQueue();
        expect(localClient.currentPendingMutations, isEmpty);
      },
    );

    test(
      'clearQueue rolls back optimistic patches to the last server baseline',
      () async {
        remoteClient.queryResults['messages:listPublic'] = <dynamic>[
          <String, dynamic>{'_id': 'server-1', 'text': 'Hello'},
        ];
        await localClient.query('messages:listPublic');
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'User',
          'text': 'Queued',
        });
        expect(localClient.currentPendingMutations, hasLength(1));
        // The optimistic patch is in the cache while the mutation is queued.
        final patched = await localClient.query('messages:listPublic');
        expect(patched, hasLength(2));

        final events = <LocalQueryEvent>[];
        final subscription = localClient.subscribe('messages:listPublic');
        addTearDown(subscription.cancel);
        subscription.stream.listen(events.add);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        await localClient.clearQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(localClient.currentPendingMutations, isEmpty);
        // The cache is restored to the last server-confirmed value: the
        // discarded mutation's message is gone.
        final restored = await localClient.query('messages:listPublic');
        expect(restored, hasLength(1));
        expect((restored as List).single['_id'], 'server-1');
        final lastSuccess = events.whereType<LocalQuerySuccess>().last;
        expect(lastSuccess.value, hasLength(1));
        expect(lastSuccess.hasPendingWrites, isFalse);
      },
    );

    test(
      'clearQueue deletes optimistic-only cache entries and reports the loss',
      () async {
        await localClient.setNetworkMode(LocalNetworkMode.offline);

        // No server value was ever cached: the optimistic patch creates the
        // cache entry from scratch (absent baseline).
        await localClient.mutate('messages:sendPublic', <String, dynamic>{
          'author': 'User',
          'text': 'Queued',
        });
        expect(await localClient.query('messages:listPublic'), hasLength(1));

        final events = <LocalQueryEvent>[];
        final subscription = localClient.subscribe('messages:listPublic');
        addTearDown(subscription.cancel);
        subscription.stream.listen(events.add);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        await localClient.clearQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // The optimistic-only entry is rolled back to its absent baseline.
        expect(
          () => localClient.query('messages:listPublic'),
          throwsA(isA<StateError>()),
        );
        expect(events.whereType<LocalQueryError>(), isNotEmpty);
      },
    );

    // ---------------------------------------------------------------
    // Dispose
    // ---------------------------------------------------------------

    test('operations throw after dispose', () async {
      await localClient.dispose();

      expect(() => localClient.query('test:q'), throwsA(isA<StateError>()));
      expect(() => localClient.subscribe('test:q'), throwsA(isA<StateError>()));
      expect(() => localClient.mutate('test:m'), throwsA(isA<StateError>()));
      expect(() => localClient.action('test:a'), throwsA(isA<StateError>()));
    });

    test(
      'openWithRemote leaves caller-owned remote alive by default',
      () async {
        await localClient.dispose();

        expect(remoteClient.disposed, isFalse);
      },
    );

    test(
      'openWithRemote disposes caller-owned remote when configured',
      () async {
        await localClient.dispose();
        store = await SqliteLocalStore.openInMemory();
        remoteClient = FakeRemoteClient();
        localClient = await ConvexLocalClient.openWithRemote(
          remoteClient: remoteClient,
          config: LocalClientConfig(
            cacheStorage: store,
            queueStorage: store,
            disposeRemoteClient: true,
          ),
        );

        await localClient.dispose();

        expect(remoteClient.disposed, isTrue);
      },
    );
  });

  group('SqliteLocalStore', () {
    test('openInMemory creates a working store', () async {
      final store = await SqliteLocalStore.openInMemory();

      // Write and read a cache entry.
      await store.upsert(
        StoredCacheEntry(
          key: 'test-key',
          queryName: 'test:query',
          argsJson: '{}',
          valueJson: '"hello"',
          updatedAtMillis: 1000,
        ),
      );
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

    test('open initializes schema version for future migrations', () async {
      final dir = await Directory.systemTemp.createTemp('dartvex-local-test-');
      addTearDown(() async {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      });
      final path = '${dir.path}/local.db';
      final store = await SqliteLocalStore.open(path);
      await store.close();

      final database = sqlite.sqlite3.open(path);
      addTearDown(database.close);

      final version =
          (database.select('PRAGMA user_version;').single['user_version']
                  as num)
              .toInt();
      expect(version, 2);
    });

    test('closes database handle when migration fails', () async {
      final database = _MigrationFailureDatabase();

      await expectLater(
        native.SqliteLocalStore.openFromDatabaseForTesting(database),
        throwsA(isA<sqlite.SqliteException>()),
      );

      expect(database.closed, isTrue);
    });

    test('read returns null for missing key', () async {
      final store = await SqliteLocalStore.openInMemory();
      final entry = await store.read('nonexistent');
      expect(entry, isNull);
      await store.close();
    });

    test('upsert overwrites existing entry', () async {
      final store = await SqliteLocalStore.openInMemory();

      await store.upsert(
        StoredCacheEntry(
          key: 'k',
          queryName: 'q',
          argsJson: '{}',
          valueJson: '"v1"',
          updatedAtMillis: 1000,
        ),
      );
      await store.upsert(
        StoredCacheEntry(
          key: 'k',
          queryName: 'q',
          argsJson: '{}',
          valueJson: '"v2"',
          updatedAtMillis: 2000,
        ),
      );

      final entry = await store.read('k');
      expect(entry!.valueJson, '"v2"');
      expect(entry.updatedAtMillis, 2000);

      await store.close();
    });

    test('clearCache and clearQueue are independent', () async {
      final store = await SqliteLocalStore.openInMemory();

      await store.upsert(
        StoredCacheEntry(
          key: 'k',
          queryName: 'q',
          argsJson: '{}',
          valueJson: '"v"',
          updatedAtMillis: 1000,
        ),
      );
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

    test('updateOptimisticData updates persisted rollback metadata', () async {
      final store = await SqliteLocalStore.openInMemory();

      final mutation = await store.enqueue(
        mutationName: 'm',
        argsJson: '{}',
        optimisticJson: '{"rollback":[]}',
        createdAtMillis: 1000,
      );

      await store.updateOptimisticData(
        mutation.id,
        '{"rollback":[{"hasEntry":true}]}',
      );

      final all = await store.loadAll();
      expect(all.single.optimisticJson, '{"rollback":[{"hasEntry":true}]}');

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

    test(
      'mutation queue preserves insertion order via auto-increment',
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
      },
    );
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

    test('roundtrips Convex special values', () {
      final value = <String, dynamic>{
        'count': BigInt.from(42),
        'bytes': Uint8List.fromList(<int>[1, 2, 3]),
        'special': double.infinity,
      };

      final decoded = codec.decode(codec.encode(value)) as Map<String, dynamic>;

      expect(decoded['count'], BigInt.from(42));
      expect(decoded['bytes'], orderedEquals(<int>[1, 2, 3]));
      expect(decoded['special'], double.infinity);
    });
  });
}

final class _MigrationFailureDatabase implements sqlite.Database {
  var closed = false;

  @override
  void close() {
    closed = true;
  }

  @override
  void execute(String sql, [List<Object?> parameters = const <Object?>[]]) {
    throw sqlite.SqliteException(
      extendedResultCode: 26,
      message: 'file is not a database',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class DelayedReadCacheStorage implements CacheStorage {
  DelayedReadCacheStorage(this._delegate, {required this.delayAfterRead});

  final CacheStorage _delegate;
  final Future<void> delayAfterRead;

  @override
  Future<void> clearCache() {
    return _delegate.clearCache();
  }

  @override
  Future<void> deleteCacheEntry(String key, {int? updatedAtMillis}) {
    return _delegate.deleteCacheEntry(key, updatedAtMillis: updatedAtMillis);
  }

  @override
  Future<void> close() {
    return _delegate.close();
  }

  @override
  Future<StoredCacheEntry?> read(String key) async {
    final entry = await _delegate.read(key);
    await delayAfterRead;
    return entry;
  }

  @override
  Future<void> upsert(StoredCacheEntry entry) {
    return _delegate.upsert(entry);
  }
}

class ThrowingCacheStorage implements CacheStorage {
  const ThrowingCacheStorage();

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteCacheEntry(String key, {int? updatedAtMillis}) async {}

  @override
  Future<StoredCacheEntry?> read(String key) async {
    throw StateError('cache read failed');
  }

  @override
  Future<void> upsert(StoredCacheEntry entry) async {}
}

class FakeRemoteClient implements LocalRemoteClient {
  final Map<String, dynamic> queryResults = <String, dynamic>{};
  final Map<String, ConvexException> queryErrors = <String, ConvexException>{};
  final Map<String, List<Object?>> mutationResults = <String, List<Object?>>{};
  final List<RemoteCall> mutationCalls = <RemoteCall>[];
  final Map<String, Stream<LocalRemoteQueryEvent>> subscriptionStreams =
      <String, Stream<LocalRemoteQueryEvent>>{};
  final Map<String, int> subscriptionCancelCounts = <String, int>{};
  final StreamController<LocalRemoteConnectionState>
  _connectionStateController =
      StreamController<LocalRemoteConnectionState>.broadcast(sync: true);
  LocalRemoteConnectionState _currentConnectionState =
      LocalRemoteConnectionState.connected;
  bool disposed = false;

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
    if (disposed) {
      return;
    }
    disposed = true;
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
    if (next is Future<Object?>) {
      return next;
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
    final stream =
        subscriptionStreams[name] ??
        Stream<LocalRemoteQueryEvent>.value(
          LocalRemoteQuerySuccess(queryResults[name]),
        );
    return FakeRemoteSubscription(
      stream,
      onCancel: () {
        subscriptionCancelCounts.update(
          name,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      },
    );
  }

  void setConnectionState(LocalRemoteConnectionState state) {
    _currentConnectionState = state;
    _connectionStateController.add(state);
  }
}

class FakeRemoteSubscription implements LocalRemoteSubscription {
  FakeRemoteSubscription(this._stream, {void Function()? onCancel})
    : _onCancel = onCancel;

  final Stream<LocalRemoteQueryEvent> _stream;
  final void Function()? _onCancel;
  bool _canceled = false;

  @override
  Stream<LocalRemoteQueryEvent> get stream => _stream;

  @override
  void cancel() {
    if (_canceled) {
      return;
    }
    _canceled = true;
    _onCancel?.call();
  }
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

class ThrowingPatchMutationHandler extends LocalMutationHandler {
  const ThrowingPatchMutationHandler();

  @override
  String get mutationName => 'tasks:throwPatch';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('tasks:list'),
        apply: (_) => throw StateError('patch failed'),
      ),
    ];
  }
}

class PartiallyThrowingPatchMutationHandler extends LocalMutationHandler {
  const PartiallyThrowingPatchMutationHandler();

  @override
  String get mutationName => 'tasks:partialThrowPatch';

  @override
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    return <LocalMutationPatch>[
      LocalMutationPatch(
        target: const LocalQueryDescriptor('tasks:list'),
        apply: (_) => const <dynamic>['optimistic'],
      ),
      LocalMutationPatch(
        target: const LocalQueryDescriptor('tasks:stats'),
        apply: (_) => throw StateError('second patch failed'),
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
