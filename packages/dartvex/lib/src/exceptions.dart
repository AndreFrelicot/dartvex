/// Exception thrown when a file upload to Convex storage fails.
class ConvexFileUploadException implements Exception {
  const ConvexFileUploadException(this.statusCode, this.body);

  /// HTTP status code returned by the upload endpoint.
  final int statusCode;

  /// Response body from the upload endpoint.
  final String body;

  @override
  String toString() =>
      'ConvexFileUploadException(statusCode: $statusCode, body: $body)';
}

class ConvexException implements Exception {
  const ConvexException(
    this.message, {
    this.data,
    this.logLines = const <String>[],
    this.retryable = false,
  });

  final String message;
  final Object? data;
  final List<String> logLines;
  final bool retryable;

  @override
  String toString() {
    return 'ConvexException(message: $message, retryable: $retryable)';
  }
}
