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

/// Exception thrown when a Convex storage URL cannot be resolved.
///
/// Typically means the resolver returned no URL because the file does not
/// exist (for example it was deleted). This is a normal runtime condition, so
/// it is surfaced as a dedicated exception rather than a [StateError].
class ConvexStorageException implements Exception {
  /// Creates a storage exception with a human-readable [message].
  const ConvexStorageException(this.message);

  /// Human-readable error message.
  final String message;

  @override
  String toString() => 'ConvexStorageException($message)';
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

  /// Whether the failure is transient: sending the operation again may succeed.
  ///
  /// This is **not** an idempotency guarantee. In particular, an action that
  /// was already sent when the connection dropped fails with
  /// `retryable: true`, yet the server may already have run it — only retry
  /// actions (and mutations with external side effects) that are safe to run
  /// twice. Failures caused by the server rejecting the request, by disposing
  /// the client, or by a fatal server error are `false`.
  final bool retryable;

  @override
  String toString() {
    return 'ConvexException(message: $message, retryable: $retryable)';
  }
}
