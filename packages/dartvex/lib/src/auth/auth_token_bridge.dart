import 'auth_provider.dart';

final class AuthTokenBridge<TUser> {
  AuthTokenBridge({
    required this.authProvider,
    required this.onIdToken,
    String? initialToken,
  }) : _cachedToken = initialToken;

  final AuthProvider<TUser> authProvider;
  final void Function(String? token) onIdToken;

  String? _cachedToken;
  Future<String?>? _refreshInFlight;

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
