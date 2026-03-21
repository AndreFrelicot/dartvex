// ignore_for_file: unused_local_variable
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';

/// Example: Use dartvex_local for offline-first Convex access with SQLite cache.
void main() async {
  // 1. Create a standard Convex client
  final convex = ConvexClient(
    'https://your-app.convex.cloud',
  );

  // 2. Create a shared SQLite store for cache + mutation queue.
  final store = await SqliteLocalStore.open('convex_cache.db');

  // 3. Wrap the remote client with offline storage.
  final localClient = await ConvexLocalClient.open(
    client: convex,
    config: LocalClientConfig(
      cacheStorage: store,
      queueStorage: store,
      disposeRemoteClient: true,
    ),
  );

  // 4. Query — returns cached data instantly, syncs in background
  final messages = await localClient.query('messages:list');

  // 5. Mutation — applied optimistically, synced when online
  await localClient.mutate('messages:send', {
    'body': 'Hello from offline!',
    'author': 'Alice',
  });

  // 6. Clean up
  await localClient.dispose();
}
