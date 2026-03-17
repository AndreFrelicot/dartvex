import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'file_downloader.dart';
import 'provider.dart';
import 'runtime_client.dart';

/// Widget that displays an image stored in Convex file storage.
///
/// Fetches the download URL by calling [getUrlAction] with the given
/// [storageId], then downloads the image with optional progress tracking.
///
/// ```dart
/// ConvexImage(
///   storageId: document.avatarId,
///   getUrlAction: 'files:getUrl',
///   placeholder: const CircularProgressIndicator(),
///   onProgress: (progress) => print('${(progress * 100).toInt()}%'),
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
    this.builder,
    this.progressBuilder,
    this.onProgress,
    this.fit,
    this.width,
    this.height,
  });

  /// The Convex storage ID of the image.
  final String storageId;

  /// The Convex query or action name that returns a download URL
  /// for a given storageId (e.g. `'files:getUrl'`).
  final String getUrlAction;

  /// Optional runtime client override. If omitted, uses [ConvexProvider.of].
  final ConvexRuntimeClient? client;

  /// Widget shown while the URL is being resolved (before download starts).
  final Widget? placeholder;

  /// Widget shown when an error occurs.
  final Widget? errorWidget;

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

  @override
  State<ConvexImage> createState() => _ConvexImageState();
}

class _ConvexImageState extends State<ConvexImage> {
  Uint8List? _bytes;
  Object? _error;
  bool _loading = true;
  ConvexDownloadProgress? _progress;
  String? _loadedStorageId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ConvexImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageId != widget.storageId ||
        oldWidget.getUrlAction != widget.getUrlAction) {
      _loadIfNeeded();
    }
  }

  void _loadIfNeeded() {
    if (_loadedStorageId == widget.storageId && _bytes != null) {
      return;
    }
    _loadedStorageId = widget.storageId;
    _fetchAndDownload();
  }

  Future<void> _fetchAndDownload() async {
    setState(() {
      _loading = true;
      _error = null;
      _progress = null;
    });

    try {
      // Step 1: resolve the download URL from Convex
      final client = widget.client ?? ConvexProvider.of(context);
      final url = await client.query(
        widget.getUrlAction,
        <String, dynamic>{'storageId': widget.storageId},
      );
      if (!mounted) return;

      final urlStr = url as String?;
      if (urlStr == null || urlStr.isEmpty) {
        throw StateError('No URL returned for storageId ${widget.storageId}');
      }

      // Step 2: download with progress tracking
      final bytes = await ConvexFileDownloader.download(
        urlStr,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
          widget.onProgress?.call(p);
        },
      );

      if (!mounted) return;
      setState(() {
        _bytes = bytes;
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
      if (widget.progressBuilder != null && _progress != null) {
        return widget.progressBuilder!(context, _progress!);
      }
      return widget.placeholder ?? const SizedBox.shrink();
    }
    if (_error != null || _bytes == null) {
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
