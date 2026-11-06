import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart' show createDefaultHttpClient;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'download_errors.dart';
import 'file_downloader.dart';
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

  /// Replaces the HTTP client a shared store downloads with, in tests.
  ///
  /// The store owns the returned client and closes it with the store.
  @visibleForTesting
  static http.Client Function(String cacheKey)? debugHttpClientFactory;

  /// Idle bound of a forced refresh's download (connection, headers, and the
  /// gap between body chunks), like [ConvexFileDownloader.download]'s default.
  static const Duration _refreshIdleTimeout = Duration(seconds: 30);

  /// Pending forced-refresh commit per cache manager and key, so two
  /// refreshes of one entry never interleave (and never orphan a file).
  static final Expando<Map<String, Future<void>>> _commits =
      Expando<Map<String, Future<void>>>();

  static final Random _random = Random.secure();

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
  /// already cached, this is a no-op unless [force] is `true`.
  ///
  /// A forced refresh downloads the whole asset before touching the cache,
  /// then stores it under a new file name and only afterwards deletes the
  /// previous file, so a failed refresh (an error status, a dropped
  /// connection mid-body, a stall longer than 30 seconds without progress)
  /// keeps serving the previous copy. This holds for the default store and
  /// for custom [CacheManager]s (downloaded through their `fileService`);
  /// other [BaseCacheManager] implementations are refreshed with their own
  /// `downloadFile(force: true)`.
  ///
  /// Errors never carry [url] beyond its origin (see
  /// [ConvexFileDownloader.download]).
  Future<File> prefetch(
    String cacheKey,
    String url, {
    bool force = false,
  }) async {
    try {
      if (force) {
        final cacheManager = _cacheManager;
        if (cacheManager is CacheManager) {
          return await _refresh(cacheManager, cacheKey, url);
        }
        final info = await cacheManager.downloadFile(
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

  /// Downloads [url] completely, then swaps it in as [cacheKey]'s file.
  ///
  /// `CacheManager.downloadFile(force: true)` is not used: when the response's
  /// content type maps to a different file extension, flutter_cache_manager
  /// deletes the cached file as soon as the headers arrive, before streaming
  /// the body, so a failed body destroyed the offline copy (and left a
  /// partial file behind).
  Future<File> _refresh(
    CacheManager cacheManager,
    String cacheKey,
    String url,
  ) async {
    final store = _store;
    final Uint8List bytes;
    final FileServiceResponse response;
    if (store != null) {
      // The default store: download through its own client, abortable and
      // bounded by the idle timeout like ConvexFileDownloader.
      final download = await downloadWithHeaders(
        url,
        client: store.httpClient,
        idleTimeout: _refreshIdleTimeout,
      );
      bytes = download.bytes;
      // Only used for the headers-derived metadata (extension, validity,
      // ETag), with flutter_cache_manager's own rules.
      response = HttpGetResponse(
        http.StreamedResponse(
          const Stream<List<int>>.empty(),
          download.statusCode,
          headers: download.headers,
        ),
      );
    } else {
      response = await cacheManager.config.fileService
          .get(url)
          .timeout(_refreshIdleTimeout);
      final status = response.statusCode;
      if (status < 200 || status >= 300) {
        unawaited(
          response.content
              .drain<void>()
              .timeout(_refreshIdleTimeout)
              .then<void>((_) {}, onError: (Object _) {}),
        );
        throw HttpExceptionWithStatus(
          status,
          'Failed to download file (status $status)',
          uri: Uri.tryParse(url),
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.content.timeout(_refreshIdleTimeout)) {
        builder.add(chunk);
      }
      bytes = builder.toBytes();
    }
    return _serializedCommit(
      cacheManager,
      cacheKey,
      () => _commit(cacheManager, cacheKey, url, bytes, response),
    );
  }

  static Future<File> _serializedCommit(
    CacheManager cacheManager,
    String cacheKey,
    Future<File> Function() commit,
  ) {
    final commits = _commits[cacheManager] ??= <String, Future<void>>{};
    final previous = commits[cacheKey];
    final result = previous == null
        ? commit()
        : previous.then((_) => commit(), onError: (Object _) => commit());
    final done = result.then<void>((_) {}, onError: (Object _) {});
    commits[cacheKey] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(commits[cacheKey], done)) {
          commits.remove(cacheKey);
        }
      }),
    );
    return result;
  }

  static Future<File> _commit(
    CacheManager cacheManager,
    String cacheKey,
    String url,
    Uint8List bytes,
    FileServiceResponse response,
  ) async {
    final store = cacheManager.store;
    // A new name (never the previous one) so a failed write cannot damage
    // the cached copy, and FileImage (keyed by path) does not keep showing
    // the previously decoded image.
    final relativePath =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${_random.nextInt(1 << 32).toRadixString(36)}'
        '${response.fileExtension}';
    final file = await store.fileSystem.createFile(relativePath);
    final previous = await store.retrieveCacheData(cacheKey);
    try {
      await file.writeAsBytes(bytes, flush: true);
      await store.putFile(
        CacheObject(
          url,
          key: cacheKey,
          relativePath: relativePath,
          validTill: response.validTill,
          eTag: response.eTag,
          id: previous?.id,
          length: bytes.length,
        ),
      );
    } catch (_) {
      await _deleteQuietly(file);
      rethrow;
    }
    if (previous != null && previous.relativePath != relativePath) {
      await _deleteQuietly(
        await store.fileSystem.createFile(previous.relativePath),
      );
    }
    return file;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on Object catch (_) {
      // Best effort: an orphaned file is only wasted space.
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
    final httpClient =
        ConvexAssetCache.debugHttpClientFactory?.call(cacheKey) ??
        createDefaultHttpClient();
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
