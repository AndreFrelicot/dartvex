import 'package:dartvex/dartvex.dart'
    show AuthSessionEndedError, ConvexException;

/// Exception thrown by the Better Auth adapter.
///
/// When Better Auth answers with an error body, the decoded JSON object is
/// available as [data] and its `code` field (for example
/// `INVALID_EMAIL_OR_PASSWORD`, `EMAIL_NOT_VERIFIED`, `USER_ALREADY_EXISTS`)
/// as [code].
///
/// [retryable] is `true` for failures that may succeed when retried: HTTP 5xx
/// and 429 responses, network errors (offline, DNS failure, reset
/// connection) and request timeouts.
class BetterAuthException extends ConvexException {
  /// Creates a Better Auth exception.
  const BetterAuthException(
    super.message, {
    super.data,
    super.logLines,
    super.retryable,
  });

  /// The Better Auth error code from [data] (for example
  /// `INVALID_EMAIL_OR_PASSWORD`), or `null` when none was returned.
  String? get code {
    final payload = data;
    if (payload is Map) {
      final value = payload['code'];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  /// Name printed by [toString]; overridden by subclasses.
  String get _typeName => 'BetterAuthException';

  @override
  String toString() {
    final errorCode = code;
    return '$_typeName(message: $message'
        '${errorCode == null ? '' : ', code: $errorCode'}'
        ', retryable: $retryable)';
  }
}

/// Exception thrown when a persisted Better Auth session is no longer valid.
///
/// Thrown when the Convex token endpoint rejects an existing session (HTTP
/// 401/403), for example while `getSession` or
/// `ConvexBetterAuthProvider.loginFromCache()` refreshes it. A token response
/// without a usable token is a plain [BetterAuthException] instead, and so is
/// a rejection of a session that sign-in, sign-up or magic-link verification
/// has just created (that new session is signed out), since neither proves
/// that the session the app already had has ended.
///
/// Note that `ConvexBetterAuthProvider.loginFromCache()` reports a session
/// that Better Auth's `get-session` no longer recognizes as a [StateError]
/// (`'Better Auth session expired.'`), not as this exception.
class BetterAuthSessionExpiredException extends BetterAuthException
    implements AuthSessionEndedError {
  /// Creates a session-expired exception.
  const BetterAuthSessionExpiredException(super.message);

  @override
  String get _typeName => 'BetterAuthSessionExpiredException';
}

/// Exception thrown when Better Auth accepted a sign-up but did not start a
/// session because the account still has to be verified.
///
/// Better Auth answers `{"token": null, "user": {...}}` when
/// `emailAndPassword.requireEmailVerification` is enabled or `autoSignIn` is
/// `false`. It returns the same generic shape when the email is already
/// registered, so it does not reveal which accounts exist. The decoded body is
/// available as [data] and the user object as [user].
///
/// Ask the user to open the verification email, then sign in.
class BetterAuthEmailVerificationRequiredException extends BetterAuthException {
  /// Creates an email-verification-required exception.
  const BetterAuthEmailVerificationRequiredException(
    super.message, {
    super.data,
  });

  /// The `user` object returned by Better Auth, if any.
  Map<String, dynamic>? get user {
    final payload = data;
    if (payload is Map) {
      final value = payload['user'];
      if (value is Map) {
        return value.cast<String, dynamic>();
      }
    }
    return null;
  }

  @override
  String get _typeName => 'BetterAuthEmailVerificationRequiredException';
}

/// Exception thrown when Better Auth requires a second factor to finish a
/// sign-in (`{"twoFactorRedirect": true}` from the `twoFactor()` plugin).
///
/// No session is created yet. This package does not wrap the two-factor
/// verification endpoints; the decoded body is available as [data] and the
/// offered methods (for example `totp`, `otp`) as [twoFactorMethods].
class BetterAuthTwoFactorRequiredException extends BetterAuthException {
  /// Creates a two-factor-required exception.
  const BetterAuthTwoFactorRequiredException(
    super.message, {
    super.data,
  });

  /// The second-factor methods Better Auth offered, if it listed any.
  List<String> get twoFactorMethods {
    final payload = data;
    if (payload is Map) {
      final value = payload['twoFactorMethods'];
      if (value is List) {
        return value.whereType<String>().toList(growable: false);
      }
    }
    return const <String>[];
  }

  @override
  String get _typeName => 'BetterAuthTwoFactorRequiredException';
}
