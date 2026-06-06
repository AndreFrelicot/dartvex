/// Serialized cache entry stored by a [CacheStorage] implementation.
class StoredCacheEntry {
  /// Creates a stored cache entry.
  const StoredCacheEntry({
    required this.key,
    required this.queryName,
    required this.argsJson,
    required this.valueJson,
    required this.updatedAtMillis,
  });

  /// Deterministic cache key derived from query name and arguments.
  final String key;

  /// Canonical Convex query name.
  final String queryName;

  /// Encoded JSON arguments for the query.
  final String argsJson;

  /// Encoded JSON query result payload.
  final String valueJson;

  /// UTC timestamp, in milliseconds since epoch, when the entry was updated.
  final int updatedAtMillis;
}

/// Decoded cache entry returned by [QueryCache].
class CachedQueryEntry {
  /// Creates a decoded cached query entry.
  const CachedQueryEntry({
    required this.key,
    required this.queryName,
    required this.args,
    required this.value,
    required this.updatedAt,
  });

  /// Deterministic cache key derived from query name and arguments.
  final String key;

  /// Canonical Convex query name.
  final String queryName;

  /// Decoded query arguments.
  final Map<String, dynamic> args;

  /// Decoded cached result value.
  final dynamic value;

  /// UTC time when the cache entry was last written.
  final DateTime updatedAt;
}

/// Persistence interface for the local query cache.
abstract class CacheStorage {
  /// Creates a cache storage implementation.
  CacheStorage();

  /// Reads a stored cache entry by its canonical [key].
  Future<StoredCacheEntry?> read(String key);

  /// Inserts or updates a stored cache [entry].
  Future<void> upsert(StoredCacheEntry entry);

  /// Deletes a single cached query entry by its canonical [key].
  ///
  /// When [updatedAtMillis] is provided, implementations should only delete the
  /// row if it still has that timestamp, avoiding deletion of a fresh value
  /// written concurrently after the stale read.
  Future<void> deleteCacheEntry(String key, {int? updatedAtMillis});

  /// Removes all cached query results.
  Future<void> clearCache();

  /// Releases any storage resources held by the implementation.
  Future<void> close();
}

/// Optional maintenance operations for cache storage implementations.
///
/// [QueryCache] uses this hook when a query cache policy requests pruning to a
/// maximum entry count. Single-entry deletion is part of [CacheStorage] because
/// optimistic rollback correctness depends on it.
abstract interface class CacheStorageMaintenance {
  /// Keeps only the newest [maxEntries] cache entries.
  Future<void> pruneCacheToSize(int maxEntries);
}
