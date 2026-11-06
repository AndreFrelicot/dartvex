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

/// Removes [requestedUrl] and every capability-bearing piece of it from
/// errors raised while downloading it.
///
/// HTTP errors keep their type and status; their message and URI field are
/// reduced to the origin. A [FormatException] (a malformed URL, rejected by
/// `Uri.parse`) keeps its type and message but loses its `source`, which is
/// the whole URL. Any other error whose description mentions the URL becomes
/// an [http.ClientException] carrying only the scrubbed description; errors
/// that do not mention it are returned unchanged.
Object redactDownloadError(Object error, String requestedUrl) {
  final requestedUri = Uri.tryParse(requestedUrl);
  if (error is FormatException) {
    return FormatException(_scrubUrls(error.message, requestedUrl));
  }
  if (error is! HttpException && error is! http.ClientException) {
    final description = error.toString();
    if (!_mentionsUrl(description, requestedUrl)) {
      return error;
    }
    return http.ClientException(
      'Download failed: ${_scrubUrls(description, requestedUrl)}',
      downloadOrigin(requestedUri ?? Uri()),
    );
  }
  final uri = error is HttpException
      ? error.uri
      : (error as http.ClientException).uri;
  final origin = downloadOrigin(uri ?? requestedUri ?? Uri());
  if (error is http.RequestAbortedException) {
    return http.RequestAbortedException(origin);
  }
  final message = error is HttpException
      ? error.message
      : (error as http.ClientException).message;
  final safeMessage = _scrubUrls(message, requestedUrl);
  if (error is HttpExceptionWithStatus) {
    return HttpExceptionWithStatus(error.statusCode, safeMessage, uri: origin);
  }
  if (error is HttpException) {
    return HttpException(safeMessage, uri: origin);
  }
  return http.ClientException(safeMessage, origin);
}

final RegExp _httpUrl = RegExp(r'https?://[^\s]+', caseSensitive: false);

/// The pieces of [url] that must never appear in an error: the URL itself,
/// any user info, and everything from the path on. Computed textually so it
/// also covers URLs `Uri.parse` rejects.
Iterable<String> _sensitiveParts(String url) {
  final parts = <String>{if (url.isNotEmpty) url};
  final schemeEnd = url.indexOf('://');
  final authorityStart = schemeEnd < 0 ? 0 : schemeEnd + 3;
  final pathStart = url.indexOf(RegExp('[/?#]'), authorityStart);
  final authority = url.substring(
    authorityStart,
    pathStart < 0 ? url.length : pathStart,
  );
  final at = authority.lastIndexOf('@');
  if (at > 0) {
    parts.add(authority.substring(0, at));
  }
  if (pathStart >= 0 && url.length - pathStart > 1) {
    parts.add(url.substring(pathStart));
  }
  return parts;
}

bool _mentionsUrl(String text, String requestedUrl) =>
    _httpUrl.hasMatch(text) ||
    _sensitiveParts(requestedUrl).any((part) => text.contains(part));

/// Scrubs whole HTTP URLs, including redirects, instead of replacing just the
/// known request string: URL prefixes and normalized percent escapes can
/// otherwise leave a capability-bearing suffix in the message. Then removes
/// what is left of [requestedUrl] (for example a malformed URL that is not
/// matched as an HTTP URL).
String _scrubUrls(String text, String requestedUrl) {
  var safe = text.replaceAllMapped(
    _httpUrl,
    (match) =>
        downloadOrigin(Uri.tryParse(match[0]!) ?? Uri())?.toString() ?? '<url>',
  );
  // Longest first, so the whole URL is replaced before its path suffix.
  final parts = _sensitiveParts(requestedUrl).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final part in parts) {
    safe = safe.replaceAll(part, '<url>');
  }
  return safe;
}
