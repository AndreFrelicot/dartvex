import '../query_key.dart';
import '../value_codec.dart';
import 'cache_storage.dart';

class QueryCache {
  const QueryCache({
    required CacheStorage storage,
    required ValueCodec codec,
  })  : _storage = storage,
        _codec = codec;

  final CacheStorage _storage;
  final ValueCodec _codec;

  Future<CachedQueryEntry?> read(
    String queryName,
    Map<String, dynamic> args,
  ) async {
    final key = serializeQueryKey(queryName, args);
    final stored = await _storage.read(key);
    if (stored == null) {
      return null;
    }
    return CachedQueryEntry(
      key: stored.key,
      queryName: stored.queryName,
      args: _codec.decodeMap(stored.argsJson),
      value: _codec.decode(stored.valueJson),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        stored.updatedAtMillis,
        isUtc: true,
      ),
    );
  }

  Future<void> write({
    required String name,
    required Map<String, dynamic> args,
    required dynamic value,
  }) {
    final now = DateTime.now().toUtc();
    return _storage.upsert(
      StoredCacheEntry(
        key: serializeQueryKey(name, args),
        queryName: canonicalizeQueryName(name),
        argsJson: _codec.encode(args),
        valueJson: _codec.encode(value),
        updatedAtMillis: now.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> clear() => _storage.clearCache();
}
