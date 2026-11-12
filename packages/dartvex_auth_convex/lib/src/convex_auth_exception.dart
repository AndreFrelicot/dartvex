import 'package:dartvex/dartvex.dart'
    show AuthSessionEndedError, ConvexException;

/// Exception thrown by the Convex Auth adapter.
///
/// [retryable] is `true` for failures that may succeed when retried: HTTP 5xx
/// and 429 responses, network and TLS errors, and request timeouts. A
/// function that threw on the server (for example a mutation that does not
/// exist, or an argument validation error) is not retryable; its
/// `ConvexError` payload, if any, is available as [data].
class ConvexAuthException extends ConvexException {
  /// Creates a Convex Auth exception.
  const ConvexAuthException(
    super.message, {
    super.data,
    super.logLines,
    super.retryable,
  });

  /// Name printed by [toString]; overridden by subclasses.
  String get _typeName => 'ConvexAuthException';

  @override
  String toString() => '$_typeName(message: $message, retryable: $retryable)';
}

/// A sign-in function answered with its `userError` arm
/// (`{status: "error", userError}`): the credentials, code or input were
/// rejected. No session was created.
///
/// [userError] is the method's error object, for example
/// `{error: "INVALID_CREDENTIALS"}` or
/// `{error: "RATE_LIMITED", retryAfterMs: 30000}`; [code] is its `error`
/// field. The codes are defined by each sign-in method of `@convex-dev/auth`.
class ConvexAuthSignInException extends ConvexAuthException {
  /// Creates a sign-in rejection for [function] with the server's
  /// [userError].
  ConvexAuthSignInException(this.function, Object? userError)
      : super(
          'Convex Auth sign-in with $function was rejected'
          '${_codeOf(userError) == null ? '' : ': ${_codeOf(userError)}'}.',
          data: userError,
        );

  /// The sign-in function that rejected the request.
  final String function;

  /// The method's `userError` object as returned by the server.
  Object? get userError => data;

  /// The `error` code of [userError] (for example `INVALID_CREDENTIALS`,
  /// `USER_NOT_FOUND`, `USERNAME_TAKEN`, `RATE_LIMITED`), or `null` when the
  /// server returned none.
  String? get code => _codeOf(data);

  /// How long to wait before trying again, when the server rate-limited the
  /// request (`retryAfterMs`).
  Duration? get retryAfter {
    final payload = data;
    if (payload is Map) {
      final value = payload['retryAfterMs'];
      if (value is num && value.isFinite && value >= 0) {
        return Duration(milliseconds: value.toInt());
      }
    }
    return null;
  }

  static String? _codeOf(Object? userError) {
    if (userError is Map) {
      final value = userError['error'];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  @override
  String get _typeName => 'ConvexAuthSignInException';

  @override
  String toString() => '$_typeName(function: $function'
      '${code == null ? '' : ', code: $code'})';
}

/// The provider has no live Convex Auth session: none was ever started or
/// restored, or the server reported it gone (`refreshSession` answered
/// `noSession` because the session expired, was revoked, or its refresh
/// token was replayed). Sign in again.
///
/// Implements [AuthSessionEndedError], so a `ConvexClientWithAuth` restore
/// that fails with it signs out instead of keeping the dead session.
class ConvexAuthSessionEndedException extends ConvexAuthException
    implements AuthSessionEndedError {
  /// Creates a session-ended exception.
  const ConvexAuthSessionEndedException(super.message);

  @override
  String get _typeName => 'ConvexAuthSessionEndedException';
}
