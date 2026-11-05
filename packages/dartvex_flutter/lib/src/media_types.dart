import 'package:flutter/widgets.dart';

// Platform-neutral types shared by the native media helpers
// (native_only_io.dart) and their web stand-ins (native_only_stub.dart).

/// Snapshot of an in-progress file download.
class ConvexDownloadProgress {
  /// Creates a download progress snapshot.
  const ConvexDownloadProgress({
    required this.received,
    required this.total,
    required this.progress,
  });

  /// Bytes received so far.
  final int received;

  /// Total bytes expected, or -1 if the server didn't send Content-Length.
  final int total;

  /// Download progress between 0.0 and 1.0, or -1.0 if total is unknown.
  final double progress;

  /// Whether the total size is known.
  bool get hasTotalSize => total > 0;
}

/// Callback that reports download progress.
typedef ConvexDownloadProgressCallback =
    void Function(ConvexDownloadProgress progress);

/// Builder for an image that failed to load: receives the error and a
/// callback that retries the load.
typedef ConvexImageErrorBuilder =
    Widget Function(BuildContext context, Object error, VoidCallback retry);

/// Optional interface custom cache managers can implement to expose metrics.
abstract interface class ConvexAssetCacheMetrics {
  /// Returns the total size of cached assets in bytes.
  Future<int> getSizeBytes();
}
