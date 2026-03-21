import 'dart:io';

import 'package:flutter/widgets.dart';

import 'asset_cache.dart';
import 'provider.dart';
import 'runtime_client.dart';

/// Widget that displays an image from Convex storage using a disk cache.
///
/// Unlike [ConvexImage], this widget persists assets to disk via
/// [ConvexAssetCache] using the stable [storageId] as cache key.
class ConvexCachedImage extends StatefulWidget {
  /// Creates a [ConvexCachedImage].
  const ConvexCachedImage({
    super.key,
    required this.storageId,
    required this.getUrlAction,
    this.cache,
    this.client,
    this.placeholder,
    this.errorWidget,
    this.builder,
    this.fit,
    this.width,
    this.height,
  });

  /// Stable cache key and storage identifier for the asset.
  final String storageId;

  /// Convex query or action that resolves the signed download URL.
  final String getUrlAction;

  /// Optional cache override. Defaults to [ConvexAssetCache.shared].
  final ConvexAssetCache? cache;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Widget shown while the image is loading.
  final Widget? placeholder;

  /// Widget shown when the image fails to load.
  final Widget? errorWidget;

  /// Optional custom builder for the resolved [ImageProvider].
  final Widget Function(BuildContext context, ImageProvider image)? builder;

  /// How the image should be inscribed into the space.
  final BoxFit? fit;

  /// Width constraint for the image.
  final double? width;

  /// Height constraint for the image.
  final double? height;

  @override
  State<ConvexCachedImage> createState() => _ConvexCachedImageState();
}

class _ConvexCachedImageState extends State<ConvexCachedImage> {
  File? _file;
  Object? _error;
  bool _loading = true;
  String? _loadedStorageId;

  ConvexAssetCache get _cache => widget.cache ?? ConvexAssetCache.shared;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ConvexCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageId != widget.storageId ||
        oldWidget.getUrlAction != widget.getUrlAction) {
      _loadIfNeeded();
    }
  }

  void _loadIfNeeded() {
    if (_loadedStorageId == widget.storageId && _file != null) {
      return;
    }
    _loadedStorageId = widget.storageId;
    _fetchAndCache();
  }

  Future<void> _fetchAndCache() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final client = widget.client ?? ConvexProvider.of(context);
      final cached = await _cache.get(widget.storageId);
      if (cached != null) {
        if (!mounted) return;
        setState(() {
          _file = cached;
          _loading = false;
        });
        return;
      }

      final url = await client.query(
        widget.getUrlAction,
        <String, dynamic>{'storageId': widget.storageId},
      );
      if (!mounted) return;

      final urlStr = url as String?;
      if (urlStr == null || urlStr.isEmpty) {
        throw StateError('No URL returned for storageId ${widget.storageId}');
      }

      final file = await _cache.prefetch(widget.storageId, urlStr);
      if (!mounted) return;
      setState(() {
        _file = file;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return widget.placeholder ?? const SizedBox.shrink();
    }
    if (_error != null || _file == null) {
      return widget.errorWidget ?? const SizedBox.shrink();
    }

    final imageProvider = FileImage(_file!);
    if (widget.builder != null) {
      return widget.builder!(context, imageProvider);
    }

    return Image(
      image: imageProvider,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
    );
  }
}
