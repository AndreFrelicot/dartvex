import 'package:dartvex/dartvex.dart' show ConvexException;

/// Exception thrown by the Better Auth adapter.
class BetterAuthException extends ConvexException {
  /// Creates a Better Auth exception.
  const BetterAuthException(
    super.message, {
    super.data,
    super.logLines,
    super.retryable,
  });
}

/// Exception thrown when a persisted Better Auth session is no longer valid.
class BetterAuthSessionExpiredException extends BetterAuthException {
  /// Creates a session-expired exception.
  const BetterAuthSessionExpiredException(super.message);
}
