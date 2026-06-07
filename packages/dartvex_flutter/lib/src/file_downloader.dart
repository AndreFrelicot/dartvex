import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
/// Native-only: [HttpClient] comes from `dart:io`, so this helper is not
/// available on Flutter web. Use browser-native loading via `Image.network` or
/// `fetch`-style APIs in web-specific UI.
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
  ///
  /// [idleTimeout] bounds how long the download may stall without progress: it
  /// applies to establishing the connection, awaiting the response headers, and
  /// the gap between received body chunks. It is an idle (inter-event) bound,
  /// not a total budget, so an arbitrarily large download that keeps making
  /// progress is never cut off, while a stalled connection fails with a
  /// [TimeoutException] instead of leaving the request hanging open.
  static Future<Uint8List> download(
    String url, {
    ConvexDownloadProgressCallback? onProgress,
    Duration idleTimeout = const Duration(seconds: 30),
  }) async {
    final uri = Uri.parse(url);
    final client = HttpClient()..connectionTimeout = idleTimeout;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(idleTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException(
          'Failed to download file (status ${response.statusCode})',
          uri: uri,
        );
      }

      final contentLength = response.contentLength;
      final hasLength = contentLength > 0;
      int received = 0;

      final builder = BytesBuilder(copy: false);

      await for (final chunk in response.timeout(idleTimeout)) {
        builder.add(chunk);
        received += chunk.length;
        onProgress?.call(ConvexDownloadProgress(
          received: received,
          total: hasLength ? contentLength : -1,
          progress: hasLength ? received / contentLength : -1,
        ));
      }

      return builder.toBytes();
    } finally {
      client.close(force: true);
    }
  }
}
