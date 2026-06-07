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
    // Let provider errors propagate instead of collapsing them to a null token.
    // Swallowing them here made every transient failure (for example a network
    // blip refreshing a still-valid session) indistinguishable from "no
    // session", which the auth manager treats as a definitive logout on a
    // scheduled refresh. The auth manager already wraps every fetchToken call in
    // try/catch, so a throw cannot crash the client; each path instead handles
    // it correctly — a scheduled refresh logs and keeps the session, while a
    // server `AuthError` still drives a genuine reauth and eventual logout. This
    // mirrors the official client, where a throwing token fetcher does not by
    // itself log the user out. The cached token is left intact on failure so a
    // transient error never discards a token that may still be valid; a genuine
    // logout flows through `loginFromCache` returning no token (or the provider
    // signalling it elsewhere), not through swallowing the error here.
    final result = await authProvider.loginFromCache(
      onIdToken: (token) {
        _cachedToken = token;
      },
    );
    final token = authProvider.extractIdToken(result);
    _cachedToken = token;
    return token;
  }
}
