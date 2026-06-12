import 'dart:io';

import 'package:dartvex/dartvex.dart' show createDefaultHttpClient;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

/// Caches binary assets (images, files) from Convex storage to disk,
/// keyed by stable storage ID rather than expiring signed URLs.
///
/// Native-only: this cache uses `dart:io` and `flutter_cache_manager`, so it is
/// not available on Flutter web. Web apps should resolve signed storage URLs
/// and render them directly, for example with `Image.network`.
class ConvexAssetCache {
  /// Shared default asset cache instance.
  static final ConvexAssetCache shared = ConvexAssetCache();

  /// Creates an asset cache backed by a default [CacheManager].
  ConvexAssetCache({
    String cacheKey = 'convexAssetCache',
    Duration stalePeriod = const Duration(days: 30),
    int maxNrOfCacheObjects = 200,
  }) : this._owned(
         createDefaultHttpClient(),
         cacheKey: cacheKey,
         stalePeriod: stalePeriod,
         maxNrOfCacheObjects: maxNrOfCacheObjects,
       );

  ConvexAssetCache._owned(
    http.Client httpClient, {
    required String cacheKey,
    required Duration stalePeriod,
    required int maxNrOfCacheObjects,
  }) : _ownedHttpClient = httpClient,
       _cacheManager = CacheManager(
         Config(
           cacheKey,
           stalePeriod: stalePeriod,
           maxNrOfCacheObjects: maxNrOfCacheObjects,
           // Route downloads through the SDK's default HTTP client so they
           // share the platform transport (NSURLSession on iOS/macOS)
           // instead of cache_manager's raw dart:io default.
           fileService: HttpFileService(httpClient: httpClient),
         ),
       );

  /// Creates an [ConvexAssetCache] wrapping an existing [BaseCacheManager].
  ///
  /// Useful for testing or custom cache configurations.
  ConvexAssetCache.custom(BaseCacheManager cacheManager)
    : _cacheManager = cacheManager,
      _ownedHttpClient = null;

  final BaseCacheManager _cacheManager;

  /// The HTTP client this cache created for its file service, closed on
  /// [dispose]. Null when wrapping a custom cache manager, whose file
  /// service's client lifecycle belongs to the caller.
  final http.Client? _ownedHttpClient;

  /// Downloads the asset at [url] and caches it under [cacheKey].
  ///
  /// [cacheKey] is a stable identifier for the asset (e.g., Convex storageId,
  /// S3 key, Cloudflare R2 path, or any custom identifier). If the asset is
  /// already cached, this is a no-op unless [force] is `true`.
  Future<File> prefetch(
    String cacheKey,
    String url, {
    bool force = false,
  }) async {
    final existing = await _cacheManager.getFileFromCache(cacheKey);
    if (existing != null && !force) {
      return existing.file;
    }
    if (existing != null) {
      await _cacheManager.removeFile(cacheKey);
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

  /// Disposes the underlying cache manager.
  Future<void> dispose() async {
    await _cacheManager.dispose();
    // CacheManager.dispose() only closes its repository, never the file
    // service's HTTP client; close the one this cache created so its
    // platform resources (an NSURLSession on iOS/macOS) are released.
    _ownedHttpClient?.close();
  }
}

/// Optional interface custom cache managers can implement to expose metrics.
abstract interface class ConvexAssetCacheMetrics {
  /// Returns the total size of cached assets in bytes.
  Future<int> getSizeBytes();
}
