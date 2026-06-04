import 'dart:async';

import 'package:dartvex/dartvex.dart' show ConvexClient, ConvexStorage;
import 'package:dartvex_flutter/dartvex_flutter.dart'
    show ConvexQuery, ConvexQuerySnapshot;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../shared/presentation/concierge_design.dart';
import '../../shared/presentation/section_card.dart';
import 'files_image_chrome.dart';
import 'files_image_support.dart';

// Raw (untyped) backend function names. The demo widgets take these directly —
// no codegen binding is needed for the storage functions.
const String _generateUploadUrl = 'files:generateUploadUrl';
const String _addImage = 'files:add';
const String _listImages = 'files:list';
const String _getImageUrl = 'files:getUrl';
const String _clearImages = 'files:clear';

/// A small bundled image the demo can upload, avoiding a file-picker dependency.
class _SampleAsset {
  const _SampleAsset({
    required this.assetPath,
    required this.filename,
    required this.caption,
    required this.contentType,
  });

  final String assetPath;
  final String filename;
  final String caption;
  final String contentType;
}

const List<_SampleAsset> _samples = <_SampleAsset>[
  _SampleAsset(
    assetPath: 'assets/sample/pasture.jpg',
    filename: 'pasture.jpg',
    caption: 'Cow in the pasture',
    contentType: 'image/jpeg',
  ),
  _SampleAsset(
    assetPath: 'assets/sample/herd.jpg',
    filename: 'herd.jpg',
    caption: 'Resting herd',
    contentType: 'image/jpeg',
  ),
];

/// The "Files" tab: Convex built-in file storage, end to end.
///
/// Upload goes through [ConvexStorage] (sign URL → POST bytes → record the
/// `storageId`), the gallery is a live `files:list` subscription, and each image
/// is rendered with platform-appropriate storage UI. Native builds showcase the
/// `dartvex_flutter` cache/offline image stack over the shared
/// `ConvexAssetCache`; web builds use signed URLs with [Image.network] and omit
/// disk-cache controls. Gated on a configured [ConvexClient]; a notice shows
/// when `CONVEX_DEMO_URL` is unset.
class FilesPanel extends StatefulWidget {
  /// Creates a [FilesPanel] driven by [client].
  const FilesPanel({super.key, required this.client});

  /// The raw client used for uploads — [ConvexStorage] needs a
  /// `ConvexFunctionCaller`, which the runtime client is not. `null` when no
  /// deployment URL is configured.
  final ConvexClient? client;

  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel> {
  static const double _gridTile = 96;
  static const double _variantTile = 116;

  bool _busy = false;
  String? _statusMessage;
  int? _cacheSizeBytes;

  @override
  void initState() {
    super.initState();
    if (filesDiskCacheSupported) {
      unawaited(_refreshCacheSize());
    }
  }

  Future<void> _upload(_SampleAsset sample) async {
    final client = widget.client;
    if (client == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage = 'Uploading ${sample.caption}…';
    });
    try {
      final storage = ConvexStorage(client);
      final data = await rootBundle.load(sample.assetPath);
      final bytes = data.buffer.asUint8List();
      final storageId = await storage.uploadFile(
        uploadUrlAction: _generateUploadUrl,
        bytes: bytes,
        filename: sample.filename,
        contentType: sample.contentType,
      );
      await client.mutate(_addImage, <String, dynamic>{
        'storageId': storageId,
        'caption': sample.caption,
      });
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Uploaded ${sample.caption} · ${_shortId(storageId)}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _statusMessage = 'Upload failed: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _clearAll() async {
    final client = widget.client;
    if (client == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage = 'Clearing stored images…';
    });
    try {
      final removed = await client.mutate(
        _clearImages,
        const <String, dynamic>{},
      );
      if (!mounted) {
        return;
      }
      setState(() => _statusMessage = 'Cleared $removed stored image(s).');
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _statusMessage = 'Clear failed: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _refreshCacheSize() async {
    if (!filesDiskCacheSupported) {
      return;
    }
    final bytes = await readAssetCacheSizeBytes();
    if (mounted) {
      setState(() => _cacheSizeBytes = bytes);
    }
  }

  Future<void> _clearCache() async {
    await clearAssetCache();
    await _refreshCacheSize();
    if (!mounted) {
      return;
    }
    setState(() => _statusMessage = 'Disk image cache cleared.');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.client == null) {
      return const _FilesBackendNotice();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildUploadCard(),
          const SizedBox(height: 20),
          ConvexQuery<List<Map<String, dynamic>>>(
            query: _listImages,
            decode: (value) => (value as List<dynamic>)
                .map((e) => (e as Map).cast<String, dynamic>())
                .toList(),
            builder: (context, snapshot) {
              final images = snapshot.data ?? const <Map<String, dynamic>>[];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildListCard(snapshot, images),
                  if (images.isNotEmpty && filesDiskCacheSupported) ...<Widget>[
                    const SizedBox(height: 20),
                    _buildVariantsCard(images.first),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUploadCard() {
    return SectionCard(
      eyebrow: 'FILE STORAGE',
      title: 'Upload to Convex storage',
      subtitle:
          'ConvexStorage runs the two-step handshake: sign an upload URL '
          '(files:generateUploadUrl), POST the bytes, then record the returned '
          'storageId (files:add). These samples are bundled assets, so no '
          'file-picker plugin is needed.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              for (final sample in _samples)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _upload(sample),
                  icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: Text('Upload ${sample.caption}'),
                ),
            ],
          ),
          if (_statusMessage != null) ...<Widget>[
            const SizedBox(height: 14),
            _StatusBanner(message: _statusMessage!, busy: _busy),
          ],
          const SizedBox(height: 14),
          const _WatchHint(
            'Each tap signs an upload URL, POSTs the bytes, and records the '
            'storageId — watch the image appear in the live gallery below.',
          ),
        ],
      ),
    );
  }

  Widget _buildListCard(
    ConvexQuerySnapshot<List<Map<String, dynamic>>> snapshot,
    List<Map<String, dynamic>> images,
  ) {
    return SectionCard(
      eyebrow: 'REACTIVE GALLERY',
      title: 'Stored images',
      subtitle: filesDiskCacheSupported
          ? 'A live subscription to files:list. Uploads and clears appear '
                'instantly; each tile is a ConvexCachedImage, disk-cached by its '
                'stable storageId.'
          : 'A live subscription to files:list. Uploads and clears appear '
                'instantly; web renders signed storage URLs with Image.network. '
                'Disk cache and offline fallback are native-only.',
      trailing: TextButton.icon(
        onPressed: (_busy || images.isEmpty) ? null : _clearAll,
        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
        label: const Text('Clear all'),
        style: TextButton.styleFrom(foregroundColor: ConciergeColors.danger),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (snapshot.isLoading && images.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: ConciergeColors.cyanSoft,
                  ),
                ),
              ),
            )
          else if (snapshot.hasError)
            Text(
              'Could not load files:list — ${snapshot.error}',
              style: const TextStyle(color: ConciergeColors.danger),
            )
          else if (images.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No images yet — upload a sample above.',
                style: TextStyle(color: ConciergeColors.textMuted),
              ),
            )
          else
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: <Widget>[
                for (final image in images)
                  if (_storageIdOf(image) case final String storageId)
                    _imageTile(
                      caption: (image['caption'] as String?) ?? '',
                      storageId: storageId,
                      size: _gridTile,
                      image: filesDiskCacheSupported
                          ? buildCachedStorageImage(
                              storageId: storageId,
                              getUrlAction: _getImageUrl,
                              size: _gridTile,
                            )
                          : _buildWebStoragePreview(storageId, _gridTile),
                    ),
              ],
            ),
          const SizedBox(height: 14),
          _WatchHint(
            filesDiskCacheSupported
                ? 'This gallery is a reactive query — no manual refresh. '
                      'Cached images survive scrolls, restarts, and offline.'
                : 'This gallery is a reactive query — no manual refresh. Web '
                      'uses signed URLs only; run a native build to demo disk '
                      'cache and offline fallback.',
          ),
        ],
      ),
    );
  }

  Widget _buildWebStoragePreview(String storageId, double size) {
    return ConvexQuery<String?>(
      query: _getImageUrl,
      args: <String, dynamic>{'storageId': storageId},
      decode: (value) => value as String?,
      builder: (context, snapshot) {
        final url = snapshot.data;
        if (snapshot.isLoading && url == null) {
          return FilesImageFrame(size: size, child: const FilesImageLoading());
        }
        if (snapshot.hasError || url == null || url.isEmpty) {
          return FilesImageFrame(size: size, child: const FilesImageError());
        }
        return FilesImageFrame(
          size: size,
          child: Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) {
                return child;
              }
              final expected = loadingProgress.expectedTotalBytes;
              final progress = expected == null || expected == 0
                  ? -1.0
                  : loadingProgress.cumulativeBytesLoaded / expected;
              return FilesImageProgress(progress);
            },
            errorBuilder: (context, error, stackTrace) {
              return const FilesImageError();
            },
          ),
        );
      },
    );
  }

  void _openImagePreview({required String storageId, required String caption}) {
    unawaited(
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        barrierColor: ConciergeColors.surfaceLowest.withValues(alpha: 0.94),
        transitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (context, animation, secondaryAnimation) {
          return _FullscreenImagePreview(
            caption: caption,
            getUrlAction: _getImageUrl,
            heroTag: _imageHeroTag(storageId),
            storageId: storageId,
          );
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.985, end: 1).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Widget _buildVariantsCard(Map<String, dynamic> newest) {
    final storageId = _storageIdOf(newest);
    return SectionCard(
      eyebrow: 'IMAGE WIDGETS',
      title: 'Three ways to render one stored image',
      subtitle:
          'The newest upload rendered by each dartvex_flutter image widget: a '
          'streaming download with progress, a disk-cached image, and the '
          'offline fallback (url: null, cache-only).',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (storageId == null)
            const Text(
              'Waiting for a storage id…',
              style: TextStyle(color: ConciergeColors.textMuted),
            )
          else
            Wrap(
              spacing: 18,
              runSpacing: 16,
              children: <Widget>[
                _variantColumn(
                  title: 'ConvexImage',
                  subtitle: 'stream + progress',
                  image: buildDownloadStorageImage(
                    storageId: storageId,
                    getUrlAction: _getImageUrl,
                    size: _variantTile,
                  ),
                ),
                _variantColumn(
                  title: 'ConvexCachedImage',
                  subtitle: 'disk cache',
                  image: buildCachedStorageImage(
                    storageId: storageId,
                    getUrlAction: _getImageUrl,
                    size: _variantTile,
                  ),
                ),
                _variantColumn(
                  title: 'ConvexOfflineImage',
                  subtitle: 'offline · url=null',
                  image: buildOfflineStorageImage(
                    storageId: storageId,
                    size: _variantTile,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 16),
          _buildCacheRow(),
          const SizedBox(height: 14),
          const _WatchHint(
            'ConvexImage re-downloads into memory (watch the ring); '
            'ConvexCachedImage persists to disk by storageId; '
            'ConvexOfflineImage shows the cached copy only — clear the cache '
            'and it falls back to "Not cached yet".',
          ),
        ],
      ),
    );
  }

  Widget _buildCacheRow() {
    if (!filesDiskCacheSupported) {
      return const Text(
        'Disk cache & offline fallback are native-only (built on dart:io); '
        'this is the web build, so the tiles above show a placeholder.',
        style: TextStyle(color: ConciergeColors.textDim, fontSize: 12.5),
      );
    }
    final size = _cacheSizeBytes;
    return Row(
      children: <Widget>[
        const Icon(
          Icons.sd_storage_outlined,
          size: 18,
          color: ConciergeColors.cyanSoft,
        ),
        const SizedBox(width: 8),
        Text(
          'Disk cache: ${size == null ? '…' : _fmtBytes(size)}',
          style: const TextStyle(
            color: ConciergeColors.textMuted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Refresh cache size',
          onPressed: _refreshCacheSize,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          color: ConciergeColors.cyanSoft,
        ),
        TextButton.icon(
          onPressed: _clearCache,
          icon: const Icon(Icons.cleaning_services_outlined, size: 18),
          label: const Text('Clear cache'),
          style: TextButton.styleFrom(foregroundColor: ConciergeColors.warning),
        ),
      ],
    );
  }

  Widget _imageTile({
    required String caption,
    required String storageId,
    required double size,
    required Widget image,
  }) {
    final label = caption.trim().isEmpty ? 'Stored image' : caption.trim();
    return SizedBox(
      width: size,
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              hoverColor: ConciergeColors.cyan.withValues(alpha: 0.08),
              splashColor: ConciergeColors.cyan.withValues(alpha: 0.16),
              onTap: () =>
                  _openImagePreview(storageId: storageId, caption: caption),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Hero(tag: _imageHeroTag(storageId), child: image),
                    const SizedBox(height: 6),
                    Text(
                      caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: ConciergeColors.textDim,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _variantColumn({
    required String title,
    required String subtitle,
    required Widget image,
  }) {
    return SizedBox(
      width: _variantTile,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ConciergeColors.cyanSoft,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ConciergeColors.textDim,
              fontSize: 10.5,
            ),
          ),
          const SizedBox(height: 8),
          image,
        ],
      ),
    );
  }

  static String? _storageIdOf(Map<String, dynamic> image) {
    final value = image['storageId'];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    return null;
  }

  static String _shortId(String id) =>
      id.length > 10 ? '${id.substring(0, 10)}…' : id;

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  static String _imageHeroTag(String storageId) => 'stored-image-$storageId';
}

class _FullscreenImagePreview extends StatelessWidget {
  const _FullscreenImagePreview({
    required this.caption,
    required this.getUrlAction,
    required this.heroTag,
    required this.storageId,
  });

  final String caption;
  final String getUrlAction;
  final Object heroTag;
  final String storageId;

  @override
  Widget build(BuildContext context) {
    final title = caption.trim().isEmpty ? 'Stored image' : caption.trim();
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 70, 18, 88),
                child: Center(
                  child: Hero(
                    tag: heroTag,
                    child: _FullscreenImageSurface(
                      getUrlAction: getUrlAction,
                      storageId: storageId,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: _FullscreenImageToolbar(title: title),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenImageSurface extends StatelessWidget {
  const _FullscreenImageSurface({
    required this.getUrlAction,
    required this.storageId,
  });

  final String getUrlAction;
  final String storageId;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        return ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            color: ConciergeColors.surfaceLowest,
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: SizedBox(
                width: maxWidth,
                height: maxHeight,
                child: _ResolvedStorageImage(
                  fit: BoxFit.contain,
                  getUrlAction: getUrlAction,
                  height: maxHeight,
                  storageId: storageId,
                  width: maxWidth,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ResolvedStorageImage extends StatelessWidget {
  const _ResolvedStorageImage({
    required this.fit,
    required this.getUrlAction,
    required this.height,
    required this.storageId,
    required this.width,
  });

  final BoxFit fit;
  final String getUrlAction;
  final double height;
  final String storageId;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ConvexQuery<String?>(
      query: getUrlAction,
      args: <String, dynamic>{'storageId': storageId},
      decode: (value) => value as String?,
      builder: (context, snapshot) {
        final url = snapshot.data;
        if (snapshot.isLoading && url == null) {
          return const Center(child: FilesImageLoading());
        }
        if (snapshot.hasError || url == null || url.isEmpty) {
          return const Center(child: FilesImageError());
        }
        return Image.network(
          url,
          width: width,
          height: height,
          fit: fit,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) {
              return child;
            }
            final expected = loadingProgress.expectedTotalBytes;
            final progress = expected == null || expected == 0
                ? -1.0
                : loadingProgress.cumulativeBytesLoaded / expected;
            return Center(child: FilesImageProgress(progress));
          },
          errorBuilder: (context, error, stackTrace) {
            return const Center(child: FilesImageError());
          },
        );
      },
    );
  }
}

class _FullscreenImageToolbar extends StatelessWidget {
  const _FullscreenImageToolbar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ConciergeColors.surfaceLow.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: ConciergeColors.cyan.withValues(alpha: 0.18),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: ConciergeColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton.filled(
          tooltip: 'Close preview',
          onPressed: () => Navigator.of(context).maybePop(),
          style: IconButton.styleFrom(
            backgroundColor: ConciergeColors.surfaceLow.withValues(alpha: 0.9),
            foregroundColor: ConciergeColors.text,
          ),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

/// A compact status line under the upload buttons.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message, required this.busy});

  final String message;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ConciergeColors.outline.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: <Widget>[
          if (busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: ConciergeColors.cyanSoft,
              ),
            )
          else
            const Icon(
              Icons.info_outline_rounded,
              size: 16,
              color: ConciergeColors.cyanSoft,
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: ConciergeColors.textMuted,
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A short "what to watch" caption rendered under each demo's controls,
/// mirroring the Sync tab's hint styling.
class _WatchHint extends StatelessWidget {
  const _WatchHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: ConciergeColors.cyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ConciergeColors.cyan.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.visibility_outlined,
            size: 16,
            color: ConciergeColors.cyanSoft,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: ConciergeColors.cyanSoft,
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilesBackendNotice extends StatelessWidget {
  const _FilesBackendNotice();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: ConciergeColors.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: ConciergeColors.warning.withValues(alpha: 0.4),
            ),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.cloud_off_rounded, color: ConciergeColors.warning),
              SizedBox(height: 12),
              Text(
                'Set CONVEX_DEMO_URL to run the file storage demo.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ConciergeColors.warning),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
