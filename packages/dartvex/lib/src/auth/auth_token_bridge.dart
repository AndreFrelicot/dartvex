import 'auth_provider.dart';

/// Bridges cached auth provider state into the token refresh contract used by Convex.
final class AuthTokenBridge<TUser> {
  /// Creates an auth token bridge.
  AuthTokenBridge({
    required this.authProvider,
    required this.onIdToken,
    String? initialToken,
  }) : _cachedToken = initialToken;

  /// Auth provider used to restore cached sessions.
  final AuthProvider<TUser> authProvider;

  /// Callback invoked when the provider emits a new ID token.
  final void Function(String? token) onIdToken;

  String? _cachedToken;
  Future<String?>? _refreshInFlight;

  /// Returns the cached token or refreshes it when [forceRefresh] is true.
  Future<String?> fetchToken({required bool forceRefresh}) {
    if (!forceRefresh) {
      return Future<String?>.value(_cachedToken);
    }
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _refreshToken();
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) {
        _refreshInFlight = null;
      }
    });
  }

  /// Updates the cached token value.
  Future<void> updateToken(String? token) async {
    _cachedToken = token;
  }

  Future<String?> _refreshToken() async {
    try {
      final result = await authProvider.loginFromCache(
        onIdToken: (token) {
          _cachedToken = token;
        },
      );
      final token = authProvider.extractIdToken(result);
      _cachedToken = token;
      return token;
    } catch (_) {
      _cachedToken = null;
      return null;
    }
  }
}
