import 'package:dartvex_auth2_convex/dartvex_auth2_convex.dart';
import 'package:flutter/foundation.dart';

/// Paths of the Convex Auth functions of the demo backend.
///
/// The adapter defaults to `auth:<name>` (the functions re-exported from
/// `convex/auth.ts`). The demo backend already uses that file for Better
/// Auth, so its Convex Auth functions live in `convex/convexAuth.ts`.
abstract final class ConvexAuthDemoFunctions {
  static const String refreshSession = 'convexAuth:refreshSession';
  static const String signOut = 'convexAuth:signOut';
  static const String signIn = 'convexAuth:signInWithUsernamePassword';
  static const String signUp = 'convexAuth:signUpWithUsernamePassword';
}

/// Where the demo keeps the Convex Auth session between two clients.
///
/// A real app writes the session to secure storage in
/// `ConvexAuthSessionProvider.onSessionChanged` and reads it back at startup
/// as `initialSession`. This store plays that role in memory: the session
/// survives a switch of auth mode (which rebuilds the Convex client), not a
/// restart of the app.
class ConvexAuthSessionStore extends ChangeNotifier {
  ConvexAuthSession? _session;
  int _rotationCount = 0;
  bool _disposed = false;

  /// The saved session, if any.
  ConvexAuthSession? get session => _session;

  /// How many times a refresh replaced the tokens of the saved session.
  int get rotationCount => _rotationCount;

  /// Saves [next], or forgets the session when it is `null`. This is the
  /// provider's `onSessionChanged` callback.
  void save(ConvexAuthSession? next) {
    final previous = _session;
    final isRotation =
        previous != null &&
        next != null &&
        previous.sessionId != null &&
        previous.sessionId == next.sessionId &&
        previous.refreshToken != next.refreshToken;
    if (isRotation) {
      _rotationCount += 1;
    } else if (next == null || previous?.sessionId != next.sessionId) {
      _rotationCount = 0;
    }
    _session = next;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A message for [error] that the demo can show to the person signing in.
///
/// A [ConvexAuthSignInException] carries the `userError` of the sign-in
/// method: its `code` is stable, so an app maps it to its own wording. The
/// other [ConvexAuthException]s describe what failed without quoting the
/// server.
String describeConvexAuthError(Object error) {
  if (error is ConvexAuthSignInException) {
    final details = error.userError;
    Object? detail(String key) => details is Map ? details[key] : null;
    return switch (error.code) {
      'INVALID_CREDENTIALS' => 'Wrong username or password.',
      'USER_NOT_FOUND' => 'No account with this username. Sign up first.',
      'USERNAME_TAKEN' => 'This username is already taken.',
      'USERNAME_TOO_SHORT' => 'Enter a username.',
      'USERNAME_TOO_LONG' =>
        'The username is too long '
            '(${detail('maximumLength')} characters at most).',
      'USERNAME_HAS_SURROUNDING_WHITESPACE' =>
        'The username cannot start or end with a space.',
      'USERNAME_HAS_INVALID_CHARACTERS' =>
        'The username contains characters that are not allowed.',
      'PASSWORD_TOO_SHORT' =>
        'The password is too short '
            '(${detail('minimumLength')} characters at least).',
      'PASSWORD_TOO_LONG' =>
        'The password is too long '
            '(${detail('maximumLength')} characters at most).',
      'PASSWORD_HAS_SURROUNDING_WHITESPACE' =>
        'The password cannot start or end with a space.',
      'PASSWORD_TOO_COMMON' => 'This password is too common. Pick another.',
      'RATE_LIMITED' => switch (error.retryAfter) {
        final Duration wait =>
          'Too many attempts. Try again in ${wait.inSeconds + 1} s.',
        null => 'Too many attempts. Try again later.',
      },
      final String code => 'Sign-in rejected: $code.',
      null => 'Sign-in rejected.',
    };
  }
  if (error is ConvexAuthException) {
    return error.retryable ? '${error.message} Try again.' : error.message;
  }
  return error.toString();
}
