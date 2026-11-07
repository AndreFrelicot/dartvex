// Web stand-ins for the native-only media helpers (native_only_io.dart).
//
// The real implementations read and write files through dart:io and
// flutter_cache_manager. The public library exports this file instead on the
// web (`dart.library.js_interop`), so JS and WASM builds keep compiling
// against the same constructors without pulling dart:io into the web import
// graph. Widgets render their error state and the cache/downloader reject
// with an UnsupportedError; on the web, resolve the signed storage URL and
// render it with `Image.network`.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'media_types.dart';
import 'runtime_client.dart';

UnsupportedError _unsupported(String api) => UnsupportedError(
  '$api is not supported on the web: it needs dart:io. Resolve the signed '
  'storage URL and render it with Image.network instead.',
);

/// Web stand-in for the native disk-backed asset cache. Every operation
/// fails with an [UnsupportedError]; [dispose] is a no-op.
class ConvexAssetCache {
  /// Shared default asset cache instance.
  static final ConvexAssetCache shared = ConvexAssetCache();

  /// Creates a web stand-in; the arguments are ignored.
  ConvexAssetCache({
    String cacheKey = 'convexAssetCache',
    Duration stalePeriod = const Duration(days: 30),
    int maxNrOfCacheObjects = 200,
  });

  /// Creates a web stand-in; [cacheManager] is ignored (on native platforms
  /// it is a `BaseCacheManager` from `flutter_cache_manager`).
  ConvexAssetCache.custom(Object cacheManager);

  /// Always fails with an [UnsupportedError] on the web.
  Future<Never> prefetch(
    String cacheKey,
    String url, {
    bool force = false,
  }) async => throw _unsupported('ConvexAssetCache.prefetch');

  /// Always fails with an [UnsupportedError] on the web.
  Future<Null> get(String cacheKey) async =>
      throw _unsupported('ConvexAssetCache.get');

  /// Always fails with an [UnsupportedError] on the web.
  Future<bool> contains(String cacheKey) async =>
      throw _unsupported('ConvexAssetCache.contains');

  /// Always fails with an [UnsupportedError] on the web.
  Future<void> remove(String cacheKey) async =>
      throw _unsupported('ConvexAssetCache.remove');

  /// Always fails with an [UnsupportedError] on the web.
  Future<void> clear() async => throw _unsupported('ConvexAssetCache.clear');

  /// Always fails with an [UnsupportedError] on the web.
  Future<int> getSizeBytes() async =>
      throw _unsupported('ConvexAssetCache.getSizeBytes');

  /// No-op on the web.
  Future<void> dispose() async {}
}

/// Web stand-in for the native file downloader.
class ConvexFileDownloader {
  ConvexFileDownloader._();

  /// Always fails with an [UnsupportedError] on the web.
  static Future<Uint8List> download(
    String url, {
    ConvexDownloadProgressCallback? onProgress,
    Duration idleTimeout = const Duration(seconds: 30),
    http.Client? client,
    Future<void>? abortTrigger,
  }) async => throw _unsupported('ConvexFileDownloader.download');
}

/// Snapshot of an asset loading operation. On the web no file is ever
/// available, so [file] is always `null`.
class ConvexAssetSnapshot {
  /// Creates an asset snapshot.
  const ConvexAssetSnapshot({
    this.file,
    this.error,
    this.isLoading = false,
    this.hasError = false,
    this.isCached = false,
  });

  /// Creates a loading snapshot with no file or error.
  const ConvexAssetSnapshot.loading()
    : file = null,
      error = null,
      isLoading = true,
      hasError = false,
      isCached = false;

  /// Always `null` on the web (a `File?` on native platforms).
  final Never? file;

  /// The error, if any.
  final Object? error;

  /// Whether the asset is currently being loaded.
  final bool isLoading;

  /// Whether the load failed.
  final bool hasError;

  /// Whether the file was served from cache.
  final bool isCached;

  /// Whether a file is available.
  bool get hasFile => file != null;
}

/// Web stand-in: builds [builder] with an [UnsupportedError] snapshot.
class ConvexOfflineImage extends StatelessWidget {
  /// Creates a [ConvexOfflineImage].
  const ConvexOfflineImage({
    super.key,
    required this.cacheKey,
    required this.cache,
    required this.builder,
    this.url,
  });

  /// A stable identifier for the asset.
  final String cacheKey;

  /// The signed URL to download from.
  final String? url;

  /// The asset cache instance to use.
  final ConvexAssetCache cache;

  /// Builds the widget tree from the current [ConvexAssetSnapshot].
  final Widget Function(BuildContext context, ConvexAssetSnapshot snapshot)
  builder;

  @override
  Widget build(BuildContext context) {
    return builder(
      context,
      ConvexAssetSnapshot(
        error: _unsupported('ConvexOfflineImage'),
        hasError: true,
      ),
    );
  }
}

/// Web stand-in: renders `errorBuilder` (with an [UnsupportedError]),
/// `errorWidget`, or nothing.
class ConvexImage extends StatelessWidget {
  /// Creates a [ConvexImage].
  const ConvexImage({
    super.key,
    required this.storageId,
    required this.getUrlAction,
    this.client,
    this.placeholder,
    this.errorWidget,
    this.errorBuilder,
    this.builder,
    this.progressBuilder,
    this.onProgress,
    this.useAction = false,
    this.fit,
    this.width,
    this.height,
    this.httpClient,
  });

  /// The Convex storage ID of the image.
  final String storageId;

  /// The Convex query or action name that returns a download URL.
  final String getUrlAction;

  /// Whether [getUrlAction] should be invoked as an action.
  final bool useAction;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Widget shown while loading.
  final Widget? placeholder;

  /// Widget shown when an error occurs.
  final Widget? errorWidget;

  /// Builder shown when an error occurs.
  final ConvexImageErrorBuilder? errorBuilder;

  /// Custom builder that receives the resolved [ImageProvider].
  final Widget Function(BuildContext context, ImageProvider image)? builder;

  /// Builder for a custom progress indicator.
  final Widget Function(BuildContext context, ConvexDownloadProgress progress)?
  progressBuilder;

  /// Callback for download progress.
  final ConvexDownloadProgressCallback? onProgress;

  /// How the image should be inscribed into the space.
  final BoxFit? fit;

  /// Width constraint for the image.
  final double? width;

  /// Height constraint for the image.
  final double? height;

  /// HTTP client used for downloads.
  final http.Client? httpClient;

  @override
  Widget build(BuildContext context) =>
      _buildUnsupported(context, 'ConvexImage', errorBuilder, errorWidget);
}

/// Web stand-in: renders `errorBuilder` (with an [UnsupportedError]),
/// `errorWidget`, or nothing.
class ConvexCachedImage extends StatelessWidget {
  /// Creates a [ConvexCachedImage].
  const ConvexCachedImage({
    super.key,
    required this.storageId,
    required this.getUrlAction,
    this.cache,
    this.client,
    this.placeholder,
    this.errorWidget,
    this.errorBuilder,
    this.builder,
    this.useAction = false,
    this.fit,
    this.width,
    this.height,
  });

  /// Stable cache key and storage identifier for the asset.
  final String storageId;

  /// Convex query or action that resolves the signed download URL.
  final String getUrlAction;

  /// Whether [getUrlAction] should be invoked as an action.
  final bool useAction;

  /// Optional cache override.
  final ConvexAssetCache? cache;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Widget shown while loading.
  final Widget? placeholder;

  /// Widget shown when the image fails to load.
  final Widget? errorWidget;

  /// Builder shown when the image fails to load.
  final ConvexImageErrorBuilder? errorBuilder;

  /// Optional custom builder for the resolved [ImageProvider].
  final Widget Function(BuildContext context, ImageProvider image)? builder;

  /// How the image should be inscribed into the space.
  final BoxFit? fit;

  /// Width constraint for the image.
  final double? width;

  /// Height constraint for the image.
  final double? height;

  @override
  Widget build(BuildContext context) => _buildUnsupported(
    context,
    'ConvexCachedImage',
    errorBuilder,
    errorWidget,
  );
}

Widget _buildUnsupported(
  BuildContext context,
  String api,
  ConvexImageErrorBuilder? errorBuilder,
  Widget? errorWidget,
) {
  if (errorBuilder != null) {
    return errorBuilder(context, _unsupported(api), () {});
  }
  return errorWidget ?? const SizedBox.shrink();
}
