import 'dart:convert';

import 'package:http/http.dart' as http;

import 'better_auth_session.dart';

/// HTTP client for Better Auth endpoints hosted on a Convex deployment.
///
/// Better Auth runs as a Convex component and exposes HTTP endpoints
/// under `/api/auth/`. This client communicates with those endpoints
/// directly — no third-party Flutter SDK needed.
class BetterAuthClient {
  BetterAuthClient({
    required this.baseUrl,
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// The Convex deployment URL (e.g. "https://your-app.convex.cloud").
  final String baseUrl;
  final http.Client _http;
  final bool _ownsHttp;

  String get _siteUrl {
    final uri = Uri.parse(baseUrl);
    final host = uri.host;
    if (host.endsWith('.convex.cloud')) {
      return uri
          .replace(host: host.replaceFirst('.convex.cloud', '.convex.site'))
          .toString();
    }
    return baseUrl;
  }

  /// Closes the underlying HTTP client (only if we created it).
  void close() {
    if (_ownsHttp) {
      _http.close();
    }
  }

  /// Signs up a new user with email and password.
  Future<BetterAuthSession> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    return _authenticate(
        '/api/auth/sign-up/email',
        {
          'name': name,
          'email': email,
          'password': password,
        },
        fallbackEmail: email);
  }

  /// Signs in an existing user with email and password.
  Future<BetterAuthSession> signIn({
    required String email,
    required String password,
  }) async {
    return _authenticate(
        '/api/auth/sign-in/email',
        {
          'email': email,
          'password': password,
        },
        fallbackEmail: email);
  }

  /// Sends a password reset email.
  Future<void> forgotPassword({
    required String email,
    String? redirectTo,
  }) async {
    await _post('/api/auth/forget-password', {
      'email': email,
      if (redirectTo != null) 'redirectTo': redirectTo,
    });
  }

  /// Resets the password using a token from the reset email.
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    await _post('/api/auth/reset-password', {
      'token': token,
      'newPassword': newPassword,
    });
  }

  /// Sends a magic link email.
  Future<void> sendMagicLink({
    required String email,
    String? callbackURL,
  }) async {
    await _post('/api/auth/magic-link/send-magic-link', {
      'email': email,
      if (callbackURL != null) 'callbackURL': callbackURL,
    });
  }

  /// Verifies a magic link token and returns a session.
  Future<BetterAuthSession> verifyMagicLink({
    required String token,
  }) async {
    final uri = Uri.parse('$_siteUrl/api/auth/magic-link/verify').replace(
      queryParameters: {'token': token},
    );
    final response = await _http.get(uri);

    if (response.statusCode != 200) {
      String detail = '';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final message = body['message'] as String?;
        if (message != null && message.isNotEmpty) {
          detail = ': $message';
        }
      } catch (_) {}
      throw StateError(
        'Magic link verification failed '
        '(status ${response.statusCode})$detail',
      );
    }

    final sessionToken = _extractSessionToken(response);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final user = body['user'] as Map<String, dynamic>?;

    final cookieJwt = _extractCookieValue(response, 'better-auth.convex_jwt');
    if (cookieJwt != null) {
      return BetterAuthSession(
        token: cookieJwt,
        sessionToken: sessionToken,
        userId: (user?['id'] as String?) ?? '',
        email: (user?['email'] as String?) ?? '',
        name: user?['name'] as String?,
      );
    }

    final convexJwt = await _fetchConvexToken(sessionToken);
    return BetterAuthSession(
      token: convexJwt,
      sessionToken: sessionToken,
      userId: (user?['id'] as String?) ?? '',
      email: (user?['email'] as String?) ?? '',
      name: user?['name'] as String?,
    );
  }

  /// Signs out the current session.
  Future<void> signOut({required String sessionToken}) async {
    await _post(
      '/api/auth/sign-out',
      {},
      bearerToken: sessionToken,
    );
  }

  /// Gets the current session, or `null` if not authenticated.
  Future<BetterAuthSession?> getSession({
    required String sessionToken,
  }) async {
    final uri = Uri.parse('$_siteUrl/api/auth/get-session');

    // Use Bearer auth (requires the `bearer()` plugin on the server).
    // This is the official approach for mobile/API clients without cookies.
    print('[Dartvex] getSession: calling $uri with Bearer token');
    final response = await _http.get(uri, headers: {
      'Authorization': 'Bearer $sessionToken',
    });
    print(
        '[Dartvex] getSession: status=${response.statusCode}, body=${response.body.length > 200 ? '${response.body.substring(0, 200)}...' : response.body}');

    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;

    final session = decoded['session'] as Map<String, dynamic>?;
    final user = decoded['user'] as Map<String, dynamic>?;
    if (session == null || user == null) return null;

    final convexJwt = await _fetchConvexToken(sessionToken);
    return BetterAuthSession(
      token: convexJwt,
      sessionToken: sessionToken,
      userId: (user['id'] as String?) ?? '',
      email: (user['email'] as String?) ?? '',
      name: user['name'] as String?,
    );
  }

  /// Common sign-up / sign-in flow: POST → extract session token → fetch JWT.
  Future<BetterAuthSession> _authenticate(
    String path,
    Map<String, dynamic> requestBody, {
    required String fallbackEmail,
  }) async {
    final response = await _post(path, requestBody);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final user = body['user'] as Map<String, dynamic>?;

    // Always extract the session token for persistence.
    final sessionToken = _extractSessionToken(response);

    // Try the Convex JWT from cookies first (avoids a second round-trip).
    final cookieJwt = _extractCookieValue(
      response,
      'better-auth.convex_jwt',
    );
    if (cookieJwt != null) {
      return BetterAuthSession(
        token: cookieJwt,
        sessionToken: sessionToken,
        userId: (user?['id'] as String?) ?? '',
        email: (user?['email'] as String?) ?? fallbackEmail,
        name: user?['name'] as String?,
      );
    }

    // Fallback: fetch JWT via /convex/token.
    final convexJwt = await _fetchConvexToken(sessionToken);

    return BetterAuthSession(
      token: convexJwt,
      sessionToken: sessionToken,
      userId: (user?['id'] as String?) ?? '',
      email: (user?['email'] as String?) ?? fallbackEmail,
      name: user?['name'] as String?,
    );
  }

  /// Fetches the Convex JWT from the Better Auth `/convex/token` endpoint.
  Future<String> _fetchConvexToken(String sessionToken) async {
    final uri = Uri.parse('$_siteUrl/api/auth/convex/token');
    final response = await _http.get(uri, headers: {
      'Authorization': 'Bearer $sessionToken',
    });

    if (response.statusCode != 200) {
      throw StateError(
        'Failed to fetch Convex token (status ${response.statusCode}).',
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['token'] as String;
  }

  String _extractSessionToken(http.Response response) {
    // Prefer the `set-auth-token` header (set by the Bearer plugin).
    // This is the official approach for mobile/API clients.
    final header = response.headers['set-auth-token'];
    print(
        '[Dartvex] _extractSessionToken: set-auth-token=${header != null ? '${header.substring(0, header.length > 30 ? 30 : header.length)}...' : 'null'}');
    if (header != null && header.isNotEmpty) {
      return header;
    }

    // Fallback: extract from set-cookie (browser flow).
    final fromCookie = _extractCookieValue(
      response,
      'better-auth.session_token',
    );
    print(
        '[Dartvex] _extractSessionToken: cookie=${fromCookie != null ? '${fromCookie.substring(0, fromCookie.length > 20 ? 20 : fromCookie.length)}...' : 'null'}');
    if (fromCookie != null) {
      return fromCookie;
    }

    throw StateError(
      'Better Auth did not return a session token '
      '(status ${response.statusCode}).',
    );
  }

  /// Extracts a cookie value from `set-cookie` headers by suffix match.
  ///
  /// Cookie names may be prefixed (e.g. `__Secure-better-auth.session_token`),
  /// so we match on the suffix.
  String? _extractCookieValue(http.Response response, String nameSuffix) {
    // `package:http` folds multiple set-cookie headers into a
    // comma-separated string.
    final raw = response.headers['set-cookie'];
    if (raw == null) return null;
    for (final part in raw.split(RegExp(r',(?=[^;]*=)'))) {
      final cookie = part.trim();
      final eqIndex = cookie.indexOf('=');
      if (eqIndex < 0) continue;
      final name = cookie.substring(0, eqIndex).trim();
      if (name.endsWith(nameSuffix)) {
        final rest = cookie.substring(eqIndex + 1);
        final semiIndex = rest.indexOf(';');
        final value = semiIndex < 0 ? rest : rest.substring(0, semiIndex);
        return Uri.decodeComponent(value.trim());
      }
    }
    return null;
  }

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> body, {
    String? bearerToken,
  }) async {
    final uri = Uri.parse('$_siteUrl$path');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
    };
    final response = await _http.post(
      uri,
      headers: headers,
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      String detail = '';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final message = body['message'] as String?;
        if (message != null && message.isNotEmpty) {
          detail = ': $message';
        }
      } catch (_) {}
      throw StateError(
        'Better Auth request to $path failed '
        '(status ${response.statusCode})$detail',
      );
    }
    return response;
  }
}
