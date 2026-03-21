// ignore_for_file: unused_local_variable
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_local/dartvex_local.dart';

/// Example: Use dartvex_local for offline-first Convex access with SQLite cache.
void main() async {
  // 1. Create a standard Convex client
  final convex = ConvexClient(
    'https://your-app.convex.cloud',
  );

  // 2. Wrap it with the local cache
  final localClient = ConvexLocalClient(
    client: convex,
    databasePath: 'convex_cache.db', // SQLite file path
  );

  // 3. Query — returns cached data instantly, syncs in background
  final messages = await localClient.query('messages:list');

  // 4. Mutation — applied optimistically, synced when online
  await localClient.mutation('messages:send', {
    'body': 'Hello from offline!',
    'author': 'Alice',
  });

  // 5. Clean up
  await localClient.close();
  convex.close();
}
