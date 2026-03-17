import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Caches binary assets (images, files) from Convex storage to disk,
/// keyed by stable storage ID rather than expiring signed URLs.
class ConvexAssetCache {
  ConvexAssetCache({
    String cacheKey = 'convexAssetCache',
    Duration stalePeriod = const Duration(days: 30),
    int maxNrOfCacheObjects = 200,
  }) : _cacheManager = CacheManager(
          Config(
            cacheKey,
            stalePeriod: stalePeriod,
            maxNrOfCacheObjects: maxNrOfCacheObjects,
          ),
        );

  /// Creates an [ConvexAssetCache] wrapping an existing [BaseCacheManager].
  ///
  /// Useful for testing or custom cache configurations.
  ConvexAssetCache.custom(BaseCacheManager cacheManager)
      : _cacheManager = cacheManager;

  final BaseCacheManager _cacheManager;

  /// Downloads the asset at [url] and caches it under [cacheKey].
  ///
  /// [cacheKey] is a stable identifier for the asset (e.g., Convex storageId,
  /// S3 key, Cloudflare R2 path, or any custom identifier). If the asset is
  /// already cached, this is a no-op.
  Future<File> prefetch(String cacheKey, String url) async {
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

  /// Disposes the underlying cache manager.
  Future<void> dispose() async {
    await _cacheManager.dispose();
  }
}
