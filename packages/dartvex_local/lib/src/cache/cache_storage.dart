class StoredCacheEntry {
  const StoredCacheEntry({
    required this.key,
    required this.queryName,
    required this.argsJson,
    required this.valueJson,
    required this.updatedAtMillis,
  });

  final String key;
  final String queryName;
  final String argsJson;
  final String valueJson;
  final int updatedAtMillis;
}

class CachedQueryEntry {
  const CachedQueryEntry({
    required this.key,
    required this.queryName,
    required this.args,
    required this.value,
    required this.updatedAt,
  });

  final String key;
  final String queryName;
  final Map<String, dynamic> args;
  final dynamic value;
  final DateTime updatedAt;
}

abstract class CacheStorage {
  Future<StoredCacheEntry?> read(String key);

  Future<void> upsert(StoredCacheEntry entry);

  Future<void> clearCache();

  Future<void> close();
}
