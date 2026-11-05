import 'dart:async';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart' show createDefaultHttpClient;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'file_downloader.dart';
import 'media_types.dart';
import 'provider.dart';
import 'runtime_client.dart';
import 'storage_url.dart';

/// Widget that displays an image stored in Convex file storage.
///
/// Fetches the download URL by calling [getUrlAction] with the given
/// [storageId], then downloads the image with optional progress tracking.
/// The URL resolver is called as a query unless [useAction] is true.
///
/// A download still running when the widget is disposed (or its [storageId]
/// changes) is aborted. Downloads share one HTTP client (one connection pool,
/// one URLSession on iOS/macOS) unless [httpClient] is provided.
///
/// On failure, [errorBuilder] receives the error and a retry callback; with
/// neither [errorBuilder] nor [errorWidget], the error is reported to
/// [FlutterError.reportError] (like `Image.network`) and nothing is shown.
///
/// Native-only in this release: progress downloads are implemented with
/// `dart:io`. On Flutter web, resolve the signed storage URL and render it with
/// `Image.network`; on web this widget is a stand-in that renders the error
/// state.
///
/// ```dart
/// ConvexImage(
///   storageId: document.avatarId,
///   getUrlAction: 'files:getUrl',
///   useAction: true,
///   placeholder: const CircularProgressIndicator(),
///   onProgress: (p) => print('${(p.progress * 100).toInt()}%'),
///   errorBuilder: (context, error, retry) =>
///       TextButton(onPressed: retry, child: const Text('Retry')),
/// )
/// ```
class ConvexImage extends StatefulWidget {
  /// Creates a widget that displays an image from Convex storage.
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

  /// The Convex query or action name that returns a download URL
  /// for a given storageId (e.g. `'files:getUrl'`).
  final String getUrlAction;

  /// Whether [getUrlAction] should be invoked as an action instead of a query.
  final bool useAction;

  /// Optional runtime client override. If omitted, uses [ConvexProvider.of].
  final ConvexRuntimeClient? client;

  /// Widget shown while the URL is being resolved (before download starts).
  final Widget? placeholder;

  /// Widget shown when an error occurs. Ignored when [errorBuilder] is set.
  final Widget? errorWidget;

  /// Builder shown when an error occurs, with the error and a retry callback.
  final ConvexImageErrorBuilder? errorBuilder;

  /// Custom builder that receives the resolved [ImageProvider].
  /// When provided, [fit], [width], and [height] are ignored.
  final Widget Function(BuildContext context, ImageProvider image)? builder;

  /// Builder for a custom progress indicator during image download.
  /// When provided, replaces the default loading indicator during download.
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

  /// HTTP client used for downloads. The widget never closes it. Defaults to
  /// one client shared by every [ConvexImage], created on first use from
  /// `createDefaultHttpClient()`.
  final http.Client? httpClient;

  @override
  State<ConvexImage> createState() => _ConvexImageState();
}

class _ConvexImageState extends State<ConvexImage> {
  /// Shared by every ConvexImage without an explicit [ConvexImage.httpClient],
  /// so downloads reuse connections instead of opening a client per image.
  static http.Client? _sharedHttpClient;

  Uint8List? _bytes;
  Object? _error;
  bool _loading = true;
  ConvexDownloadProgress? _progress;
  String? _loadedStorageId;
  String? _loadedGetUrlAction;
  bool? _loadedUseAction;
  ConvexRuntimeClient? _loadedClient;
  int _requestGeneration = 0;
  Completer<void>? _abortDownload;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ConvexImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageId != widget.storageId ||
        oldWidget.getUrlAction != widget.getUrlAction ||
        oldWidget.useAction != widget.useAction ||
        oldWidget.client != widget.client) {
      _loadIfNeeded();
    }
  }

  @override
  void dispose() {
    _requestGeneration += 1;
    _abortPendingDownload();
    super.dispose();
  }

  void _abortPendingDownload() {
    final abort = _abortDownload;
    _abortDownload = null;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
  }

  void _loadIfNeeded() {
    final client = widget.client ?? ConvexProvider.of(context);
    if (_loadedStorageId == widget.storageId &&
        _loadedGetUrlAction == widget.getUrlAction &&
        _loadedUseAction == widget.useAction &&
        _loadedClient == client &&
        (_loading || _bytes != null || _error != null)) {
      return;
    }
    _loadedStorageId = widget.storageId;
    _loadedGetUrlAction = widget.getUrlAction;
    _loadedUseAction = widget.useAction;
    _loadedClient = client;
    _fetchAndDownload(++_requestGeneration, client);
  }

  void _retry() {
    final client = _loadedClient;
    if (!mounted || client == null) {
      return;
    }
    _fetchAndDownload(++_requestGeneration, client);
  }

  Future<void> _fetchAndDownload(
    int generation,
    ConvexRuntimeClient client,
  ) async {
    final storageId = widget.storageId;
    final getUrlAction = widget.getUrlAction;
    final useAction = widget.useAction;
    _abortPendingDownload();
    final abort = _abortDownload = Completer<void>();
    setState(() {
      _loading = true;
      _error = null;
      _progress = null;
      _bytes = null;
    });

    try {
      // Step 1: resolve the download URL from Convex
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
      )) {
        return;
      }

      final urlStr = requireStorageUrl(url, storageId);

      // Step 2: download with progress tracking
      final bytes = await ConvexFileDownloader.download(
        urlStr,
        client:
            widget.httpClient ??
            (_sharedHttpClient ??= createDefaultHttpClient()),
        abortTrigger: abort.future,
        onProgress: (p) {
          if (!_isCurrentRequest(
            generation,
            storageId,
            getUrlAction,
            useAction,
            client,
          )) {
            return;
          }
          setState(() => _progress = p);
          widget.onProgress?.call(p);
        },
      );

      if (!_isCurrentRequest(
        generation,
        storageId,
        getUrlAction,
        useAction,
        client,
      )) {
        return;
      }
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (error, stackTrace) {
      if (!_isCurrentRequest(
        generation,
        storageId,
        getUrlAction,
        useAction,
        client,
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
              'while loading ConvexImage for storageId "$storageId"',
            ),
          ),
        );
      }
    } finally {
      if (identical(_abortDownload, abort)) {
        _abortDownload = null;
      }
    }
  }

  bool _isCurrentRequest(
    int generation,
    String storageId,
    String getUrlAction,
    bool useAction,
    ConvexRuntimeClient client,
  ) {
    return mounted &&
        generation == _requestGeneration &&
        widget.storageId == storageId &&
        widget.getUrlAction == getUrlAction &&
        widget.useAction == useAction &&
        _loadedClient == client;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      if (widget.progressBuilder != null && _progress != null) {
        return widget.progressBuilder!(context, _progress!);
      }
      return widget.placeholder ?? const SizedBox.shrink();
    }
    final error = _error;
    if (error != null || _bytes == null) {
      final errorBuilder = widget.errorBuilder;
      if (errorBuilder != null) {
        return errorBuilder(
          context,
          error ?? StateError('No image data'),
          _retry,
        );
      }
      return widget.errorWidget ?? const SizedBox.shrink();
    }

    final imageProvider = MemoryImage(_bytes!);
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
