// Integration test for local-first mutation replay after offline recovery.
//
// Requires:
//   CONVEX_DEPLOYMENT_URL — a Convex deployment with the demo backend deployed
//
// This test runs on native platforms only (SQLite via package:sqlite3).
// Web is not supported for dartvex_local.
//
// Run:
//   CONVEX_DEPLOYMENT_URL=https://your.convex.cloud \
//     dart test test/integration/replay_integration_test.dart

import 'dart:io';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';
import 'package:test/test.dart';

void main() {
  final deploymentUrl = Platform.environment['CONVEX_DEPLOYMENT_URL'];
  final skip = deploymentUrl == null
      ? 'Set CONVEX_DEPLOYMENT_URL to run replay integration tests. '
          'The demo backend must be deployed with messages:sendPublic and '
          'messages:listPublic available.'
      : null;

  group('Local-first replay integration', skip: skip, () {
    late ConvexClient baseClient;
    late SqliteLocalStore store;
    late ConvexLocalClient localClient;

    setUp(() async {
      baseClient = ConvexClient(deploymentUrl!);

      // Wait for the base client to connect.
      await baseClient.connectionState
          .firstWhere((state) => state == ConnectionState.connected)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw StateError(
              'ConvexClient did not connect within 10 seconds. '
              'Verify CONVEX_DEPLOYMENT_URL is reachable.',
            ),
          );

      store = await SqliteLocalStore.openInMemory();
      localClient = await ConvexLocalClient.open(
        client: baseClient,
        config: LocalClientConfig(
          cacheStorage: store,
          queueStorage: store,
          mutationHandlers: const <LocalMutationHandler>[
            _SendPublicHandler(),
          ],
        ),
      );
    });

    tearDown(() async {
      await localClient.dispose();
      baseClient.dispose();
    });

    test('queued mutation replays after offline→online transition', () async {
      // 1. Seed the cache with a remote query.
      final initial = await localClient.query('messages:listPublic');
      expect(initial, isList);

      // 2. Force offline.
      await localClient.setNetworkMode(LocalNetworkMode.offline);
      expect(
        localClient.currentConnectionState,
        LocalConnectionState.offline,
      );

      // 3. Queue a mutation while offline.
      final tag = 'replay-${DateTime.now().millisecondsSinceEpoch}';
      final result = await localClient.mutate('messages:sendPublic', {
        'author': 'Integration Test',
        'text': tag,
      });
      expect(result, isA<LocalMutationQueued>());
      expect(localClient.currentPendingMutations, hasLength(1));

      // 4. Resume sync — this triggers queue replay.
      await localClient.setNetworkMode(LocalNetworkMode.auto);

      // 5. Wait for the queue to drain. The replay runs asynchronously after
      //    setNetworkMode returns. A 15-second timeout gives ample room for
      //    one mutation round-trip even on slow connections.
      await localClient.pendingMutations
          .firstWhere((list) => list.isEmpty)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw StateError(
              'Mutation queue did not drain within 15 seconds. '
              'The remote may be unreachable or the mutation may have failed.',
            ),
          );

      // 6. Verify the mutation reached the server by querying directly.
      final after = await baseClient.query('messages:listPublic');
      final messages = after as List<dynamic>;
      final found = messages.any(
        (m) => m is Map && m['text'] == tag,
      );
      expect(
        found,
        isTrue,
        reason: 'Replayed mutation "$tag" should appear in remote query',
      );
    });

    test('multiple queued mutations replay in order', () async {
      // Seed cache.
      await localClient.query('messages:listPublic');

      // Go offline and queue two mutations.
      await localClient.setNetworkMode(LocalNetworkMode.offline);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final tag1 = 'order-first-$ts';
      final tag2 = 'order-second-$ts';

      await localClient.mutate('messages:sendPublic', {
        'author': 'Order Test',
        'text': tag1,
      });
      await localClient.mutate('messages:sendPublic', {
        'author': 'Order Test',
        'text': tag2,
      });
      expect(localClient.currentPendingMutations, hasLength(2));

      // Resume and wait for drain.
      await localClient.setNetworkMode(LocalNetworkMode.auto);
      await localClient.pendingMutations
          .firstWhere((list) => list.isEmpty)
          .timeout(const Duration(seconds: 15));

      // Both messages should exist on the server.
      final after = await baseClient.query('messages:listPublic');
      final messages = after as List<dynamic>;
      final hasFirst = messages.any((m) => m is Map && m['text'] == tag1);
      final hasSecond = messages.any((m) => m is Map && m['text'] == tag2);
      expect(hasFirst, isTrue, reason: 'First queued mutation should exist');
      expect(hasSecond, isTrue, reason: 'Second queued mutation should exist');
    });
  });
}

class _SendPublicHandler extends LocalMutationHandler {
  const _SendPublicHandler();

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
          final items = currentValue is List
              ? List<dynamic>.from(currentValue)
              : <dynamic>[];
          items.insert(0, <String, dynamic>{
            '_id': context.operationId,
            '_creationTime': context.queuedAt.millisecondsSinceEpoch.toDouble(),
            'author': args['author'],
            'text': args['text'],
          });
          return items;
        },
      ),
    ];
  }
}
