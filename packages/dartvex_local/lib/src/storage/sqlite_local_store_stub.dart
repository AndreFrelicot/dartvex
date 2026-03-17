import '../cache/cache_storage.dart';
import '../offline/queue_storage.dart';

class SqliteLocalStore implements CacheStorage, QueueStorage {
  const SqliteLocalStore._();

  static Future<SqliteLocalStore> open(String path) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  static Future<SqliteLocalStore> openInMemory() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> clearCache() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> clearQueue() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> close() async {}

  @override
  Future<StoredPendingMutation> enqueue({
    required String mutationName,
    required String argsJson,
    required String? optimisticJson,
    required int createdAtMillis,
  }) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<List<StoredPendingMutation>> loadAll() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> markStatus(
    int id,
    String status, {
    String? errorMessage,
  }) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<StoredCacheEntry?> read(String key) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> upsert(StoredCacheEntry entry) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> remove(int id) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> updateArgs(int id, String argsJson) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> saveIdRemap(String localId, String serverId) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<Map<String, String>> loadIdRemaps() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override
  Future<void> clearIdRemaps() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }
}
