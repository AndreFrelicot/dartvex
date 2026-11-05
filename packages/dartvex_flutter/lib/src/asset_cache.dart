import 'dart:io';

import 'package:dartvex/dartvex.dart' show createDefaultHttpClient;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'download_errors.dart';
import 'media_types.dart';

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
/// and render them directly, for example with `Image.network`. On web, every
/// operation fails with an `UnsupportedError`.
class ConvexAssetCache {
  /// Shared default asset cache instance.
  static final ConvexAssetCache shared = ConvexAssetCache();

  /// Store per cache key, shared by every default-constructed instance.
  static final Map<String, _SharedStore> _stores = <String, _SharedStore>{};

  /// Pending close of the last store per cache key; a new store for the key
  /// opens its metadata repository only after it, so the two never touch the
  /// same database or JSON file at once.
  static final Map<String, Future<void>> _closing = <String, Future<void>>{};

  /// Creates the metadata repository of a shared store.
  ///
  /// Defaults to the repository `flutter_cache_manager` picks for the
  /// platform (SQLite on Android, iOS and macOS; a JSON file elsewhere).
  /// Tests replace it to avoid depending on a platform backend.
  @visibleForTesting
  static CacheInfoRepository Function(String cacheKey)? debugRepositoryFactory;

  /// Replaces the disk filesystem in tests that exercise store lifecycle.
  @visibleForTesting
  static FileSystem Function(String cacheKey)? debugFileSystemFactory;

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
      repository: _OpenTrackingRepository(
        (debugRepositoryFactory ?? _defaultRepository)(cacheKey),
        openAfter: _closing[cacheKey],
      ),
    );
    store.references += 1;
    return ConvexAssetCache._(store.cacheManager, store: store);
  }

  /// Number of live default-constructed instances sharing [cacheKey]'s store.
  @visibleForTesting
  static int debugReferenceCount(String cacheKey) =>
      _stores[cacheKey]?.references ?? 0;

  static CacheInfoRepository _defaultRepository(String cacheKey) {
    // Mirrors flutter_cache_manager's own default (its `Config`).
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return CacheObjectProvider(databaseName: cacheKey);
    }
    return JsonCacheInfoRepository(databaseName: cacheKey);
  }

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
    try {
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
      return await _cacheManager.getSingleFile(url, key: cacheKey);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(redactDownloadError(error, url), stackTrace);
    }
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
    final cacheKey = store.cacheKey;
    if (identical(_stores[cacheKey], store)) {
      _stores.remove(cacheKey);
    }
    final closed = store.close();
    _closing[cacheKey] = closed;
    try {
      await closed;
    } finally {
      if (identical(_closing[cacheKey], closed)) {
        _closing.remove(cacheKey);
      }
    }
  }
}

/// One [CacheManager] (and its HTTP client) per cache key.
class _SharedStore {
  _SharedStore(this.cacheKey, this.cacheManager, this.httpClient);

  factory _SharedStore.create(
    String cacheKey, {
    required Duration stalePeriod,
    required int maxNrOfCacheObjects,
    required CacheInfoRepository repository,
  }) {
    final httpClient = createDefaultHttpClient();
    return _SharedStore(
      cacheKey,
      CacheManager(
        Config(
          cacheKey,
          stalePeriod: stalePeriod,
          maxNrOfCacheObjects: maxNrOfCacheObjects,
          repo: repository,
          fileSystem:
              ConvexAssetCache.debugFileSystemFactory?.call(cacheKey) ??
              IOFileSystem(cacheKey),
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

  /// Closes the cache manager's repository and the HTTP client.
  Future<void> close() async {
    try {
      await cacheManager.dispose();
    } finally {
      // CacheManager.dispose() only closes its repository, never the file
      // service's HTTP client; close the one the store created so its
      // platform resources (an NSURLSession on iOS/macOS) are released.
      httpClient.close();
    }
  }
}

/// Delegating [CacheInfoRepository] that only closes what was opened.
///
/// `CacheManager.dispose()` calls `close()` on its repository without
/// waiting for the `open()` its store started, and both built-in
/// repositories dereference state that only a completed open sets
/// (`CacheObjectProvider.db!`, the JSON repository's file). Disposing a cache
/// right after creating it, or after its open failed (no SQLite plugin, an
/// unreadable support directory), therefore threw a null-check error. Here
/// `close()` waits for the pending open and skips the inner close when it
/// failed.
///
/// A failed open is not rethrown from [open]: the store keeps that future
/// without a listener, so the error would surface as an uncaught async
/// error. Every later operation fails with it instead.
///
/// [openAfter] delays opening until a previous store for the same key has
/// closed.
class _OpenTrackingRepository implements CacheInfoRepository {
  _OpenTrackingRepository(this._inner, {Future<void>? openAfter})
    : _openAfter = openAfter;

  final CacheInfoRepository _inner;
  final Future<void>? _openAfter;
  Future<bool>? _opening;
  Object? _openError;
  StackTrace? _openStackTrace;

  @override
  Future<bool> open() {
    final previous = _opening;
    final opening = _open(previous);
    _opening = opening;
    return opening;
  }

  Future<bool> _open(Future<bool>? previous) async {
    final openAfter = _openAfter;
    if (openAfter != null) {
      // A failed close of the previous store must not block this one.
      await openAfter.then((_) {}, onError: (Object _) {});
    }
    if (previous != null) {
      // Keep the inner open calls in order.
      await previous;
    }
    if (_openError != null) {
      return false;
    }
    try {
      return await _inner.open();
    } on Object catch (error, stackTrace) {
      _openError = error;
      _openStackTrace = stackTrace;
      return false;
    }
  }

  @override
  Future<bool> close() async {
    final opening = _opening;
    if (opening == null) {
      // Never opened: nothing to close.
      return true;
    }
    await opening;
    if (_openError != null) {
      // The open failed, so there is no connection to close.
      return true;
    }
    return _inner.close();
  }

  Future<T> _whenOpen<T>(Future<T> Function() operation) {
    final error = _openError;
    if (error != null) {
      return Future<T>.error(error, _openStackTrace);
    }
    return operation();
  }

  @override
  Future<bool> exists() => _inner.exists();

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) =>
      _whenOpen(() => _inner.updateOrInsert(cacheObject));

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) => _whenOpen(
    () => _inner.insert(cacheObject, setTouchedToNow: setTouchedToNow),
  );

  @override
  Future<CacheObject?> get(String key) => _whenOpen(() => _inner.get(key));

  @override
  Future<int> delete(int id) => _whenOpen(() => _inner.delete(id));

  @override
  Future<int> deleteAll(Iterable<int> ids) =>
      _whenOpen(() => _inner.deleteAll(ids));

  @override
  Future<int> update(CacheObject cacheObject, {bool setTouchedToNow = true}) =>
      _whenOpen(
        () => _inner.update(cacheObject, setTouchedToNow: setTouchedToNow),
      );

  @override
  Future<List<CacheObject>> getAllObjects() => _whenOpen(_inner.getAllObjects);

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) =>
      _whenOpen(() => _inner.getObjectsOverCapacity(capacity));

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) =>
      _whenOpen(() => _inner.getOldObjects(maxAge));

  @override
  Future<void> deleteDataFile() => _inner.deleteDataFile();
}
