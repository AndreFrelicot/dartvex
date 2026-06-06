import '../query_key.dart';
import '../value_codec.dart';
import 'cache_storage.dart';

/// Policy controlling how long query cache entries remain usable.
class QueryCachePolicy {
  /// Creates a query cache policy.
  const QueryCachePolicy({this.maxEntries, this.maxEntryAge})
    : assert(maxEntries == null || maxEntries > 0);

  /// Leaves cached entries unbounded and valid until explicitly cleared.
  static const unbounded = QueryCachePolicy();

  /// Maximum number of query entries to retain, keeping newest writes first.
  ///
  /// This requires the configured storage to implement
  /// [CacheStorageMaintenance]. Storage implementations without maintenance
  /// hooks ignore this cap.
  final int? maxEntries;

  /// Maximum age for a cached entry to be returned by [QueryCache.read].
  ///
  /// Expired entries are treated as cache misses and deleted after read.
  final Duration? maxEntryAge;

  bool _isExpired(DateTime updatedAt, DateTime now) {
    final maxAge = maxEntryAge;
    if (maxAge == null) {
      return false;
    }
    return now.difference(updatedAt) > maxAge;
  }
}

/// High-level helper for reading and writing cached query results.
class QueryCache {
  /// Creates a query cache backed by [storage] and [codec].
  const QueryCache({
    required CacheStorage storage,
    required ValueCodec codec,
    QueryCachePolicy policy = QueryCachePolicy.unbounded,
  }) : _storage = storage,
       _codec = codec,
       _policy = policy;

  final CacheStorage _storage;
  final ValueCodec _codec;
  final QueryCachePolicy _policy;

  /// Reads and decodes a cached entry for [queryName] and [args].
  Future<CachedQueryEntry?> read(
    String queryName,
    Map<String, dynamic> args,
  ) async {
    final key = serializeQueryKey(queryName, args);
    final stored = await _storage.read(key);
    if (stored == null) {
      return null;
    }
    final updatedAt = DateTime.fromMillisecondsSinceEpoch(
      stored.updatedAtMillis,
      isUtc: true,
    );
    if (_policy._isExpired(updatedAt, DateTime.now().toUtc())) {
      await _storage.deleteCacheEntry(
        stored.key,
        updatedAtMillis: stored.updatedAtMillis,
      );
      return null;
    }
    return CachedQueryEntry(
      key: stored.key,
      queryName: stored.queryName,
      args: _codec.decodeMap(stored.argsJson),
      value: _codec.decode(stored.valueJson),
      updatedAt: updatedAt,
    );
  }

  /// Writes [value] into the cache for the query identified by [name] and [args].
  Future<void> write({
    required String name,
    required Map<String, dynamic> args,
    required dynamic value,
  }) async {
    final now = DateTime.now().toUtc();
    await _storage.upsert(
      StoredCacheEntry(
        key: serializeQueryKey(name, args),
        queryName: canonicalizeQueryName(name),
        argsJson: _codec.encode(args),
        valueJson: _codec.encode(value),
        updatedAtMillis: now.millisecondsSinceEpoch,
      ),
    );
    final maxEntries = _policy.maxEntries;
    final maintenance = _storage is CacheStorageMaintenance
        ? _storage as CacheStorageMaintenance
        : null;
    if (maxEntries != null && maintenance != null) {
      await maintenance.pruneCacheToSize(maxEntries);
    }
  }

  /// Clears all cached query results.
  Future<void> clear() => _storage.clearCache();
}
