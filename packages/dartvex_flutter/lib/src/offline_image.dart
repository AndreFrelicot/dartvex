import 'dart:io';

import 'package:flutter/widgets.dart';

import 'asset_cache.dart';

/// A widget that displays an asset with offline support.
///
/// Uses [ConvexAssetCache] to serve cached files when [url] is unavailable.
/// When [url] is provided, the asset is downloaded and cached for future
/// offline use. When [url] is `null` (e.g. while offline), only the cache
/// is consulted.
///
/// Native-only: this widget reads cached files through `dart:io` and is not
/// supported on Flutter web. Web apps should render signed storage URLs directly
/// and avoid assuming a disk-backed offline image cache.
///
/// Works with any storage backend: Convex Storage, Cloudflare R2, S3, etc.
/// Just provide a stable [cacheKey] that uniquely identifies the asset.
///
/// ```dart
/// ConvexOfflineImage(
///   cacheKey: task['imageId'], // e.g. Convex storageId, S3 key, etc.
///   url: imageUrl, // null when offline
///   cache: assetCache,
///   builder: (context, snapshot) {
///     if (snapshot.isLoading) return CircularProgressIndicator();
///     if (snapshot.hasError) return Icon(Icons.broken_image);
///     return Image.file(snapshot.file!, fit: BoxFit.cover);
///   },
/// )
/// ```
class ConvexOfflineImage extends StatefulWidget {
  /// Creates a [ConvexOfflineImage].
  const ConvexOfflineImage({
    super.key,
    required this.cacheKey,
    required this.cache,
    required this.builder,
    this.url,
  });

  /// A stable identifier for the asset (e.g., Convex storageId, S3 key, or any custom ID).
  /// Used as the cache key to identify the asset across app restarts.
  final String cacheKey;

  /// The signed URL to download from. Pass `null` when offline.
  final String? url;

  /// The asset cache instance to use.
  final ConvexAssetCache cache;

  /// Builds the widget tree from the current [ConvexAssetSnapshot].
  final Widget Function(BuildContext context, ConvexAssetSnapshot snapshot)
      builder;

  @override
  State<ConvexOfflineImage> createState() => _ConvexOfflineImageState();
}

class _ConvexOfflineImageState extends State<ConvexOfflineImage> {
  ConvexAssetSnapshot _snapshot = const ConvexAssetSnapshot.loading();
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load(++_requestGeneration, widget.cache);
  }

  @override
  void didUpdateWidget(covariant ConvexOfflineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.url != widget.url ||
        oldWidget.cache != widget.cache) {
      _load(++_requestGeneration, widget.cache);
    }
  }

  Future<void> _load(int generation, ConvexAssetCache cache) async {
    final cacheKey = widget.cacheKey;
    final url = widget.url;
    if (mounted) {
      setState(() {
        _snapshot = const ConvexAssetSnapshot.loading();
      });
    }

    try {
      // Try cache first.
      final cached = await cache.get(cacheKey);
      if (cached != null) {
        if (_isCurrentRequest(generation, cacheKey, url, cache)) {
          setState(() {
            _snapshot = ConvexAssetSnapshot(
              file: cached,
              isLoading: false,
              isCached: true,
            );
          });
        }
        return;
      }

      // No cache hit — download if URL available.
      if (url == null) {
        if (_isCurrentRequest(generation, cacheKey, url, cache)) {
          setState(() {
            _snapshot = const ConvexAssetSnapshot(
              error: 'No cached asset and no URL available',
              isLoading: false,
              hasError: true,
            );
          });
        }
        return;
      }

      final file = await cache.prefetch(cacheKey, url);
      if (_isCurrentRequest(generation, cacheKey, url, cache)) {
        setState(() {
          _snapshot = ConvexAssetSnapshot(
            file: file,
            isLoading: false,
            isCached: false,
          );
        });
      }
    } catch (error) {
      if (_isCurrentRequest(generation, cacheKey, url, cache)) {
        setState(() {
          _snapshot = ConvexAssetSnapshot(
            error: error,
            isLoading: false,
            hasError: true,
          );
        });
      }
    }
  }

  bool _isCurrentRequest(
    int generation,
    String cacheKey,
    String? url,
    ConvexAssetCache cache,
  ) {
    return mounted &&
        generation == _requestGeneration &&
        widget.cacheKey == cacheKey &&
        widget.url == url &&
        identical(widget.cache, cache);
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _snapshot);
  }
}

/// Snapshot of an asset loading operation.
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

  /// The resolved file, or `null` if still loading or failed.
  final File? file;

  /// The error, if any.
  final Object? error;

  /// Whether the asset is currently being loaded.
  final bool isLoading;

  /// Whether the load failed.
  final bool hasError;

  /// Whether the file was served from cache (vs. freshly downloaded).
  final bool isCached;

  /// Whether a file is available.
  bool get hasFile => file != null;
}
