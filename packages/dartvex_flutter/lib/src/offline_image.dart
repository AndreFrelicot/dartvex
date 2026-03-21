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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ConvexOfflineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey || oldWidget.url != widget.url) {
      _load();
    }
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _snapshot = const ConvexAssetSnapshot.loading();
      });
    }

    try {
      // Try cache first.
      final cached = await widget.cache.get(widget.cacheKey);
      if (cached != null) {
        if (mounted) {
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
      final url = widget.url;
      if (url == null) {
        if (mounted) {
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

      final file = await widget.cache.prefetch(widget.cacheKey, url);
      if (mounted) {
        setState(() {
          _snapshot = ConvexAssetSnapshot(
            file: file,
            isLoading: false,
            isCached: false,
          );
        });
      }
    } catch (error) {
      if (mounted) {
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
