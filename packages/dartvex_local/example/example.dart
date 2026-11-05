// ignore_for_file: unused_local_variable
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';

/// Example: Use dartvex_local for offline-first Convex access with SQLite cache.
void main() async {
  // 1. Create a standard Convex client
  final convex = ConvexClient('https://your-deployment.convex.cloud');

  // 2. Create a shared SQLite store for cache + mutation queue. Use a
  //    persistent, app-private path: in Flutter, for example
  //    `'${(await getApplicationSupportDirectory()).path}/convex_cache.db'`
  //    (package:path_provider). Relative paths fail on iOS/Android, and a temp
  //    directory loses the offline queue.
  final store = await SqliteLocalStore.open(
    '/path/to/app/data/convex_cache.db',
  );

  // 3. Wrap the remote client with offline storage.
  final localClient = await ConvexLocalClient.open(
    client: convex,
    config: LocalClientConfig(
      cacheStorage: store,
      queueStorage: store,
      disposeRemoteClient: true,
    ),
  );

  // 4. Query — fetched from the remote while connected (and cached); served
  //    from the cache while offline or disconnected.
  final messages = await localClient.query('messages:list');

  // 5. Mutation — sent directly while online; queued (and patched by any
  //    registered LocalMutationHandler) while offline, then replayed.
  //    Server rejections come back as LocalMutationFailed, not exceptions.
  final result = await localClient.mutate('messages:send', {
    'body': 'Hello from offline!',
    'author': 'Alice',
  });
  switch (result) {
    case LocalMutationSuccess(:final value):
      print('Sent: $value');
    case LocalMutationQueued(:final queuePosition):
      print('Queued at position $queuePosition');
    case LocalMutationFailed(:final error):
      print('Rejected: $error');
  }

  // 6. Clean up
  await localClient.dispose();
}
