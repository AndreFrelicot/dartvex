import 'dart:io';

import 'package:flutter/widgets.dart';

import 'asset_cache.dart';
import 'media_types.dart';
import 'provider.dart';
import 'runtime_client.dart';
import 'storage_url.dart';

/// Widget that displays an image from Convex storage using a disk cache.
///
/// Unlike [ConvexImage], this widget persists assets to disk via
/// [ConvexAssetCache] using the stable [storageId] as cache key. The URL
/// resolver is called as a query unless [useAction] is true.
///
/// When the URL resolver ([getUrlAction], [useAction]) or the provider client
/// changes after a load, the cached copy is deliberately bypassed and
/// refreshed: a different resolver or deployment may serve different content
/// for the same [storageId]. The refreshed download only replaces the cached
/// file once it succeeded.
///
/// On failure, [errorBuilder] receives the error and a retry callback; with
/// neither [errorBuilder] nor [errorWidget], the error is reported to
/// [FlutterError.reportError] and nothing is shown.
///
/// Native-only: disk-backed image caching uses `dart:io` and is not supported
/// on Flutter web. Web apps should resolve the signed storage URL and render it
/// with `Image.network`; on web this widget is a stand-in that renders the
/// error state.
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

  /// Whether [getUrlAction] should be invoked as an action instead of a query.
  final bool useAction;

  /// Optional cache override. Defaults to [ConvexAssetCache.shared].
  final ConvexAssetCache? cache;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Widget shown while the image is loading.
  final Widget? placeholder;

  /// Widget shown when the image fails to load. Ignored when [errorBuilder]
  /// is set.
  final Widget? errorWidget;

  /// Builder shown when the image fails to load, with the error and a retry
  /// callback.
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
  State<ConvexCachedImage> createState() => _ConvexCachedImageState();
}

class _ConvexCachedImageState extends State<ConvexCachedImage> {
  File? _file;
  Object? _error;
  bool _loading = true;
  String? _loadedStorageId;
  String? _loadedGetUrlAction;
  bool? _loadedUseAction;
  ConvexAssetCache? _loadedCache;
  ConvexRuntimeClient? _loadedClient;
  int _requestGeneration = 0;

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
        oldWidget.getUrlAction != widget.getUrlAction ||
        oldWidget.useAction != widget.useAction ||
        oldWidget.client != widget.client ||
        oldWidget.cache != widget.cache) {
      _loadIfNeeded();
    }
  }

  void _loadIfNeeded() {
    final client = widget.client ?? ConvexProvider.of(context);
    final cache = _cache;
    final loadedGetUrlAction = _loadedGetUrlAction;
    final loadedUseAction = _loadedUseAction;
    final loadedCache = _loadedCache;
    final loadedClient = _loadedClient;
    if (_loadedStorageId == widget.storageId &&
        loadedGetUrlAction == widget.getUrlAction &&
        loadedUseAction == widget.useAction &&
        identical(loadedCache, cache) &&
        loadedClient == client &&
        (_loading || _file != null || _error != null)) {
      return;
    }
    final shouldBypassCache =
        loadedGetUrlAction != null &&
        (loadedGetUrlAction != widget.getUrlAction ||
            loadedUseAction != widget.useAction ||
            loadedClient != client);
    _loadedStorageId = widget.storageId;
    _loadedGetUrlAction = widget.getUrlAction;
    _loadedUseAction = widget.useAction;
    _loadedCache = cache;
    _loadedClient = client;
    _fetchAndCache(
      ++_requestGeneration,
      client,
      cache: cache,
      bypassCache: shouldBypassCache,
    );
  }

  void _retry() {
    final client = _loadedClient;
    final cache = _loadedCache;
    if (!mounted || client == null || cache == null) {
      return;
    }
    _fetchAndCache(++_requestGeneration, client, cache: cache);
  }

  Future<void> _fetchAndCache(
    int generation,
    ConvexRuntimeClient client, {
    required ConvexAssetCache cache,
    bool bypassCache = false,
  }) async {
    final storageId = widget.storageId;
    final getUrlAction = widget.getUrlAction;
    final useAction = widget.useAction;
    setState(() {
      _loading = true;
      _error = null;
      _file = null;
    });

    try {
      if (!bypassCache) {
        final cached = await cache.get(storageId);
        if (cached != null) {
          if (!_isCurrentRequest(
            generation,
            storageId,
            getUrlAction,
            useAction,
            client,
            cache,
          )) {
            return;
          }
          setState(() {
            _file = cached;
            _loading = false;
          });
          return;
        }
      }

      final args = <String, dynamic>{'storageId': storageId};
      final url = useAction
          ? await client.action(getUrlAction, args)
          : await client.query(getUrlAction, args);
      if (!_isCurrentRequest(
        generation,
        storageId,
        getUrlAction,
        useAction,
        client,
        cache,
      )) {
        return;
      }

      final urlStr = requireStorageUrl(url, storageId);

      final file = await cache.prefetch(storageId, urlStr, force: bypassCache);
      if (!_isCurrentRequest(
        generation,
        storageId,
        getUrlAction,
        useAction,
        client,
        cache,
      )) {
        return;
      }
      setState(() {
        _file = file;
        _loading = false;
      });
    } catch (error, stackTrace) {
      if (!_isCurrentRequest(
        generation,
        storageId,
        getUrlAction,
        useAction,
        client,
        cache,
      )) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
      if (widget.errorBuilder == null && widget.errorWidget == null) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'dartvex_flutter',
            context: ErrorDescription(
              'while loading ConvexCachedImage for storageId "$storageId"',
            ),
          ),
        );
      }
    }
  }

  bool _isCurrentRequest(
    int generation,
    String storageId,
    String getUrlAction,
    bool useAction,
    ConvexRuntimeClient client,
    ConvexAssetCache cache,
  ) {
    return mounted &&
        generation == _requestGeneration &&
        widget.storageId == storageId &&
        widget.getUrlAction == getUrlAction &&
        widget.useAction == useAction &&
        _loadedClient == client &&
        identical(_loadedCache, cache);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return widget.placeholder ?? const SizedBox.shrink();
    }
    final error = _error;
    if (error != null || _file == null) {
      final errorBuilder = widget.errorBuilder;
      if (errorBuilder != null) {
        return errorBuilder(
          context,
          error ?? StateError('No cached file'),
          _retry,
        );
      }
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
