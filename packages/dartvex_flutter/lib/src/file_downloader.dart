import 'dart:io';

import 'package:flutter/foundation.dart';

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
typedef ConvexDownloadProgressCallback = void Function(
  ConvexDownloadProgress progress,
);

/// Downloads files from URLs with byte-level progress tracking.
///
/// Uses Dart's [HttpClient] to stream the response, providing real-time
/// progress updates suitable for UI indicators.
///
/// ```dart
/// final bytes = await ConvexFileDownloader.download(
///   url,
///   onProgress: (p) {
///     print('${p.received}/${p.total} bytes (${(p.progress * 100).toInt()}%)');
///   },
/// );
/// ```
class ConvexFileDownloader {
  /// Utility class; use static methods only.
  ConvexFileDownloader._();

  /// Downloads the file at [url] and returns its bytes.
  ///
  /// [onProgress] is called as bytes are received with a
  /// [ConvexDownloadProgress] containing received bytes, total bytes,
  /// and progress ratio.
  static Future<Uint8List> download(
    String url, {
    ConvexDownloadProgressCallback? onProgress,
  }) async {
    final request = await HttpClient().getUrl(Uri.parse(url));
    final response = await request.close();

    final contentLength = response.contentLength;
    final hasLength = contentLength > 0;
    int received = 0;

    final chunks = <List<int>>[];

    await for (final chunk in response) {
      chunks.add(chunk);
      received += chunk.length;
      onProgress?.call(ConvexDownloadProgress(
        received: received,
        total: hasLength ? contentLength : -1,
        progress: hasLength ? received / contentLength : -1,
      ));
    }

    final bytes = Uint8List(received);
    int offset = 0;
    for (final chunk in chunks) {
      bytes.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    return bytes;
  }
}
