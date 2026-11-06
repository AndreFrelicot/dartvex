import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart' show createDefaultHttpClient;
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show HttpExceptionWithStatus;
import 'package:http/http.dart' as http;

import 'download_errors.dart';
import 'media_types.dart';

/// Downloads files from URLs with byte-level progress tracking.
///
/// Streams the response through the SDK's default HTTP client
/// (`createDefaultHttpClient`), so downloads share the platform transport —
/// NSURLSession on iOS/macOS — and provide real-time progress updates
/// suitable for UI indicators.
///
/// Native-only: this helper is not available on Flutter web. Use
/// browser-native loading via `Image.network` or `fetch`-style APIs in
/// web-specific UI; on web, [download] fails with an `UnsupportedError`.
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
  /// [client] is used for the request when given and is left open (the
  /// caller owns it); reusing one client across downloads reuses its
  /// connections (and, on iOS/macOS, its URLSession). Without it, a client
  /// from `createDefaultHttpClient()` is created for this download and closed
  /// afterwards.
  ///
  /// A non-2xx response fails with an [HttpException] (an
  /// `HttpExceptionWithStatus` carrying the status code). Errors never carry
  /// the URL beyond its origin: storage paths and signed queries are bearer
  /// capabilities, so they are scrubbed from messages, URI fields and (for a
  /// malformed URL) the [FormatException] source.
  ///
  /// Completing [abortTrigger] aborts the download: it fails with
  /// `http.RequestAbortedException` and the transfer stops (for clients that
  /// support aborting, which includes every default platform client).
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
    http.Client? client,
    Future<void>? abortTrigger,
  }) async {
    final download = await downloadWithHeaders(
      url,
      onProgress: onProgress,
      idleTimeout: idleTimeout,
      client: client,
      abortTrigger: abortTrigger,
    );
    return download.bytes;
  }
}

/// A completed download: the body and the response it came with.
typedef DownloadResult = ({
  Uint8List bytes,
  int statusCode,
  Map<String, String> headers,
});

/// [ConvexFileDownloader.download], also returning the response status and
/// headers (the asset cache derives the file extension and validity from
/// them). A non-2xx status fails with [HttpExceptionWithStatus].
Future<DownloadResult> downloadWithHeaders(
  String url, {
  ConvexDownloadProgressCallback? onProgress,
  Duration idleTimeout = const Duration(seconds: 30),
  http.Client? client,
  Future<void>? abortTrigger,
}) async {
  // Created lazily inside the try below, so a malformed URL never opens a
  // client that would have to be closed.
  http.Client? ownedClient;
  // Fired by the caller's [abortTrigger] or by a failure (a timeout of
  // send() or of the error-body drain only stops *waiting*), so a stalled
  // request is never left running on the client.
  final abort = Completer<void>();
  void fireAbort() {
    if (!abort.isCompleted) {
      abort.complete();
    }
  }

  abortTrigger?.then((_) => fireAbort(), onError: (Object _) => fireAbort());
  try {
    // Parsed inside the try: Uri.parse's FormatException carries the whole
    // (capability-bearing) URL as its source and must be redacted too.
    final uri = Uri.parse(url);
    final httpClient = client ?? (ownedClient = createDefaultHttpClient());
    // The send() timeout bounds connection establishment and response
    // headers together — the same stall window dart:io's connectionTimeout
    // plus close().timeout() used to cover.
    final response = await httpClient
        .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future))
        .timeout(idleTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      try {
        // Draining the error body is best-effort cleanup; bound it by the
        // idle timeout so a stalled error response cannot hang the download,
        // and never let a drain failure mask the status error thrown below.
        await response.stream.drain<void>().timeout(idleTimeout);
      } catch (_) {}
      throw HttpExceptionWithStatus(
        response.statusCode,
        'Failed to download file (status ${response.statusCode})',
        uri: downloadOrigin(uri),
      );
    }

    final contentLength = response.contentLength ?? -1;
    final hasLength = contentLength > 0;
    int received = 0;

    final builder = BytesBuilder(copy: false);

    await for (final chunk in response.stream.timeout(idleTimeout)) {
      builder.add(chunk);
      received += chunk.length;
      onProgress?.call(
        ConvexDownloadProgress(
          received: received,
          total: hasLength ? contentLength : -1,
          progress: hasLength ? received / contentLength : -1,
        ),
      );
    }

    return (
      bytes: builder.toBytes(),
      statusCode: response.statusCode,
      headers: response.headers,
    );
  } catch (error, stackTrace) {
    fireAbort();
    Error.throwWithStackTrace(redactDownloadError(error, url), stackTrace);
  } finally {
    ownedClient?.close();
  }
}
