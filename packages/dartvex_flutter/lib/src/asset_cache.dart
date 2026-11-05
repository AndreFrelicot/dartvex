import 'dart:io';

import 'package:dartvex/dartvex.dart' show createDefaultHttpClient;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// Caches binary assets (images, files) from Convex storage to disk,
/// keyed by stable storage ID rather than expiring signed URLs.
///
/// Instances created with the same `cacheKey` share one underlying
/// [CacheManager] (one database, one file directory): `ConvexAssetCache()`
/// and [ConvexAssetCache.shared] use the same default key and therefore the
/// same store. The first instance created for a key decides its
/// `stalePeriod` and `maxNrOfCacheObjects`, and [dispose] only closes the
/// store once every instance using it has been disposed. Use a distinct
/// `cacheKey` for a separate cache.
///
/// Native-only: this cache uses `dart:io` and `flutter_cache_manager`, so it is
/// not available on Flutter web. Web apps should resolve signed storage URLs
/// and render them directly, for example with `Image.network`.
class ConvexAssetCache {
  /// Shared default asset cache instance.
  static final ConvexAssetCache shared = ConvexAssetCache();

  /// Store per cache key, shared by every default-constructed instance.
  static final Map<String, _SharedStore> _stores = <String, _SharedStore>{};

  /// Creates an asset cache backed by the [CacheManager] for [cacheKey].
  ///
  /// See the class documentation for how instances with the same key share
  /// one store.
  factory ConvexAssetCache({
    String cacheKey = 'convexAssetCache',
    Duration stalePeriod = const Duration(days: 30),
    int maxNrOfCacheObjects = 200,
  }) {
    final store = _stores[cacheKey] ??= _SharedStore.create(
      cacheKey,
      stalePeriod: stalePeriod,
      maxNrOfCacheObjects: maxNrOfCacheObjects,
    );
    store.references += 1;
    return ConvexAssetCache._(store.cacheManager, store: store);
  }

  /// Number of live default-constructed instances sharing [cacheKey]'s store.
  @visibleForTesting
  static int debugReferenceCount(String cacheKey) =>
      _stores[cacheKey]?.references ?? 0;

  ConvexAssetCache._(this._cacheManager, {_SharedStore? store})
    : _store = store;

  /// Creates an [ConvexAssetCache] wrapping an existing [BaseCacheManager].
  ///
  /// Useful for testing or custom cache configurations. The caller owns the
  /// manager's configuration; [dispose] disposes it.
  ConvexAssetCache.custom(BaseCacheManager cacheManager)
    : _cacheManager = cacheManager,
      _store = null;

  final BaseCacheManager _cacheManager;

  /// The shared store this instance holds a reference to, or null for a
  /// custom cache manager.
  final _SharedStore? _store;
  bool _disposed = false;

  /// Downloads the asset at [url] and caches it under [cacheKey].
  ///
  /// [cacheKey] is a stable identifier for the asset (e.g., Convex storageId,
  /// S3 key, Cloudflare R2 path, or any custom identifier). If the asset is
  /// already cached, this is a no-op unless [force] is `true`. A forced
  /// refresh replaces the cached file only once the new download succeeded;
  /// a failed refresh keeps the previous copy.
  Future<File> prefetch(
    String cacheKey,
    String url, {
    bool force = false,
  }) async {
    if (force) {
      final info = await _cacheManager.downloadFile(
        url,
        key: cacheKey,
        force: true,
      );
      return info.file;
    }
    final existing = await _cacheManager.getFileFromCache(cacheKey);
    if (existing != null) {
      return existing.file;
    }
    return _cacheManager.getSingleFile(url, key: cacheKey);
  }

  /// Returns the cached file for [cacheKey], or `null` if not cached.
  Future<File?> get(String cacheKey) async {
    final info = await _cacheManager.getFileFromCache(cacheKey);
    return info?.file;
  }

  /// Returns `true` if an asset with [cacheKey] is in the cache.
  Future<bool> contains(String cacheKey) async {
    final info = await _cacheManager.getFileFromCache(cacheKey);
    return info != null;
  }

  /// Removes a single cached asset by [cacheKey].
  Future<void> remove(String cacheKey) {
    return _cacheManager.removeFile(cacheKey);
  }

  /// Clears all cached assets.
  Future<void> clear() {
    return _cacheManager.emptyCache();
  }

  /// Returns the total size, in bytes, of the cached assets.
  ///
  /// Size introspection is only guaranteed for the default [CacheManager]
  /// implementation or custom managers that implement
  /// [ConvexAssetCacheMetrics].
  Future<int> getSizeBytes() async {
    final cacheManager = _cacheManager;
    if (cacheManager is ConvexAssetCacheMetrics) {
      return (cacheManager as ConvexAssetCacheMetrics).getSizeBytes();
    }
    if (cacheManager is CacheManager) {
      return cacheManager.store.getCacheSize();
    }
    throw UnsupportedError(
      'Cache size is unavailable for this custom cache manager.',
    );
  }

  /// Releases this instance.
  ///
  /// A custom cache manager is disposed directly. A shared store (default
  /// constructor) is closed, together with the HTTP client it created, once
  /// every instance using its `cacheKey` has been disposed; disposing your
  /// own `ConvexAssetCache()` therefore never closes the database that
  /// [shared] is still using. Calling [dispose] more than once is a no-op.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final store = _store;
    if (store == null) {
      await _cacheManager.dispose();
      return;
    }
    store.references -= 1;
    if (store.references > 0) {
      return;
    }
    if (identical(_stores[store.cacheKey], store)) {
      _stores.remove(store.cacheKey);
    }
    await store.cacheManager.dispose();
    // CacheManager.dispose() only closes its repository, never the file
    // service's HTTP client; close the one the store created so its
    // platform resources (an NSURLSession on iOS/macOS) are released.
    store.httpClient.close();
  }
}

/// One [CacheManager] (and its HTTP client) per cache key.
class _SharedStore {
  _SharedStore(this.cacheKey, this.cacheManager, this.httpClient);

  factory _SharedStore.create(
    String cacheKey, {
    required Duration stalePeriod,
    required int maxNrOfCacheObjects,
  }) {
    final httpClient = createDefaultHttpClient();
    return _SharedStore(
      cacheKey,
      CacheManager(
        Config(
          cacheKey,
          stalePeriod: stalePeriod,
          maxNrOfCacheObjects: maxNrOfCacheObjects,
          // Route downloads through the SDK's default HTTP client so they
          // share the platform transport (NSURLSession on iOS/macOS)
          // instead of cache_manager's raw dart:io default.
          fileService: HttpFileService(httpClient: httpClient),
        ),
      ),
      httpClient,
    );
  }

  final String cacheKey;
  final CacheManager cacheManager;
  final http.Client httpClient;
  int references = 0;
}

/// Optional interface custom cache managers can implement to expose metrics.
abstract interface class ConvexAssetCacheMetrics {
  /// Returns the total size of cached assets in bytes.
  Future<int> getSizeBytes();
}
