import 'package:dartvex/dartvex.dart'
    show AuthSessionEndedError, ConvexException;

/// Exception thrown by the Convex Auth adapter.
///
/// [retryable] is `true` for failures that may succeed when retried: HTTP 5xx
/// and 429 responses, network and TLS errors, and request timeouts. A
/// function that threw on the server (for example a mutation that does not
/// exist, or an argument validation error) is not retryable; its
/// `ConvexError` payload, if any, is available as [data].
///
/// [message] and [toString] only describe what failed (the operation, the
/// HTTP status, an error code, whether it is retryable), so they are safe to
/// log. Text written by the server is kept apart in [serverMessage] and
/// `logLines`: it may quote arguments or other sensitive values, so read it
/// on purpose and do not send it to telemetry.
class ConvexAuthException extends ConvexException {
  /// Creates a Convex Auth exception.
  const ConvexAuthException(
    super.message, {
    super.data,
    super.logLines,
    super.retryable,
    this.statusCode,
    this.serverMessage,
  });

  /// The HTTP status of the response, when the failure is one.
  final int? statusCode;

  /// The error message the server wrote, when a function threw. Not part of
  /// [message] or [toString]: it may contain sensitive values.
  final String? serverMessage;

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
///
/// [message] and [toString] only name the function and the [code], so they
/// are safe to log. Anything else the server answered, including an `error`
/// that is free text instead of a code, is only in [userError].
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
  ///
  /// Only a value shaped like a code is returned: letters, digits and
  /// underscores, starting with a letter, 64 characters at most. A sign-in
  /// function of your own that puts a sentence in `error` gets `null` here,
  /// so that text (which may quote what the user typed) cannot reach a log
  /// through [message]; read it from [userError].
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
      if (value is String && _codeShape.hasMatch(value)) {
        return value;
      }
    }
    return null;
  }

  static final RegExp _codeShape = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');

  @override
  String get _typeName => 'ConvexAuthSignInException';

  @override
  String toString() => '$_typeName(function: $function'
      '${code == null ? '' : ', code: $code'})';
}

/// The provider has no live Convex Auth session: none was ever started or
/// restored, or the server reported it gone (`refreshSession` answered
/// `noSession` because the session expired, was revoked, or was ended after
/// an outdated refresh token was presented). Sign in again.
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
