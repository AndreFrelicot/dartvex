/// Exception thrown when a file upload to Convex storage fails.
class ConvexFileUploadException implements Exception {
  /// Creates a file upload exception from an HTTP [statusCode] and response [body].
  const ConvexFileUploadException(this.statusCode, this.body);

  /// HTTP status code returned by the upload endpoint.
  final int statusCode;

  /// Response body from the upload endpoint.
  final String body;

  @override
  String toString() =>
      'ConvexFileUploadException(statusCode: $statusCode, body: $body)';
}

/// Exception thrown when a Convex request or protocol operation fails.
class ConvexException implements Exception {
  /// Creates a Convex exception.
  const ConvexException(
    this.message, {
    this.data,
    this.logLines = const <String>[],
    this.retryable = false,
  });

  /// Human-readable error message.
  final String message;

  /// Optional structured error payload from Convex.
  final Object? data;

  /// Optional log lines attached to the failure.
  final List<String> logLines;

  /// Whether retrying the operation may succeed.
  final bool retryable;

  @override
  String toString() {
    return 'ConvexException(message: $message, retryable: $retryable)';
  }
}
