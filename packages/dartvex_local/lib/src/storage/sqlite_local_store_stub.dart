import '../cache/cache_storage.dart';
import '../offline/queue_storage.dart';

/// Stub [SqliteLocalStore] used on platforms without SQLite support.
class SqliteLocalStore implements CacheStorage, QueueStorage {
  /// Creates the unsupported-platform stub.
  const SqliteLocalStore._();

  /// Throws because SQLite storage is unavailable on this platform.
  static Future<SqliteLocalStore> open(String path) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  /// Throws because in-memory SQLite is unavailable on this platform.
  static Future<SqliteLocalStore> openInMemory() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<void> clearCache() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<void> clearQueue() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// No-op close for the unsupported-platform stub.
  Future<void> close() async {}

  @override

  /// Throws because SQLite storage is unavailable on this platform.
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

  /// Throws because SQLite storage is unavailable on this platform.
  Future<List<StoredPendingMutation>> loadAll() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
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

  /// Throws because SQLite storage is unavailable on this platform.
  Future<StoredCacheEntry?> read(String key) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<void> upsert(StoredCacheEntry entry) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<void> remove(int id) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<void> updateArgs(int id, String argsJson) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<void> saveIdRemap(String localId, String serverId) {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<Map<String, String>> loadIdRemaps() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }

  @override

  /// Throws because SQLite storage is unavailable on this platform.
  Future<void> clearIdRemaps() {
    throw UnsupportedError(
      'SqliteLocalStore is not available on this platform',
    );
  }
}
