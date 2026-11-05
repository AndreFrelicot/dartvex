import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

/// Storage paths and signed queries are bearer capabilities. Only the origin
/// belongs in errors that can reach Flutter's global error/crash reporters.
Uri? downloadOrigin(Uri uri) {
  if (uri.host.isEmpty) {
    return null;
  }
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

/// Preserves HTTP error types/status while removing the request URL and any
/// redirected URL from both the message and the exception's URI field.
Object redactDownloadError(Object error, String requestedUrl) {
  if (error is! HttpException && error is! http.ClientException) {
    return error;
  }
  final uri = error is HttpException
      ? error.uri
      : (error as http.ClientException).uri;
  final requestedUri = Uri.tryParse(requestedUrl);
  final origin = downloadOrigin(uri ?? requestedUri ?? Uri());
  if (error is http.RequestAbortedException) {
    return http.RequestAbortedException(origin);
  }
  final message = error is HttpException
      ? error.message
      : (error as http.ClientException).message;
  // Scrub whole HTTP URLs, including redirects, instead of replacing just
  // the known request string: URL prefixes and normalized percent escapes
  // can otherwise leave a capability-bearing suffix in the message.
  final safeMessage = message.replaceAllMapped(
    RegExp(r'https?://[^\s]+', caseSensitive: false),
    (match) =>
        downloadOrigin(Uri.tryParse(match[0]!) ?? Uri())?.toString() ?? '<url>',
  );
  if (error is HttpExceptionWithStatus) {
    return HttpExceptionWithStatus(error.statusCode, safeMessage, uri: origin);
  }
  if (error is HttpException) {
    return HttpException(safeMessage, uri: origin);
  }
  return http.ClientException(safeMessage, origin);
}
