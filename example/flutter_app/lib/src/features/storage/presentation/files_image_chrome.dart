import 'package:flutter/material.dart';

import '../../shared/presentation/concierge_design.dart';

/// Web-safe visual chrome shared by the native and web image-support modules.
///
/// These widgets never touch `dart:io`, so they compile on every platform; the
/// platform-specific modules (`files_image_support_io.dart` /
/// `files_image_support_stub.dart`) wrap their image widgets in [FilesImageFrame]
/// and reuse the loading / error / progress / unsupported states below.

/// A fixed-size, rounded, clipped frame for a stored-image tile.
class FilesImageFrame extends StatelessWidget {
  const FilesImageFrame({super.key, required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ConciergeColors.cyan.withValues(alpha: 0.18)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Center(child: child),
    );
  }
}

/// Indeterminate loading state shown while a URL resolves / bytes download.
class FilesImageLoading extends StatelessWidget {
  const FilesImageLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(
        strokeWidth: 2.4,
        color: ConciergeColors.cyanSoft,
      ),
    );
  }
}

/// Determinate download-progress ring used by the streaming image widget.
class FilesImageProgress extends StatelessWidget {
  const FilesImageProgress(this.progress, {super.key});

  /// Download ratio in `[0, 1]`, or negative when the size is unknown.
  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(
        strokeWidth: 2.4,
        color: ConciergeColors.cyanSoft,
        value: progress >= 0 ? progress.clamp(0.0, 1.0) : null,
      ),
    );
  }
}

/// Error / empty state with an explanatory [label].
class FilesImageError extends StatelessWidget {
  const FilesImageError({super.key, this.label = 'Unavailable'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.broken_image_outlined,
            size: 22,
            color: ConciergeColors.textDim,
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: ConciergeColors.textDim,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown on web, where the disk-cache / offline image stack (built on
/// `dart:io`) is unavailable. The upload and live list still work; only the
/// bitmap rendering degrades to this placeholder.
class FilesImageUnsupported extends StatelessWidget {
  const FilesImageUnsupported({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.phone_iphone_rounded,
            size: 22,
            color: ConciergeColors.textDim,
          ),
          SizedBox(height: 6),
          Text(
            'Native only',
            textAlign: TextAlign.center,
            style: TextStyle(color: ConciergeColors.textDim, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
