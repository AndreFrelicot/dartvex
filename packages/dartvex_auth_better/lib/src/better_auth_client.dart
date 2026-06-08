import 'dart:convert';

import 'package:http/http.dart' as http;

import 'better_auth_exception.dart';
import 'better_auth_session.dart';

/// HTTP client for Better Auth endpoints hosted on a Convex deployment.
///
/// Better Auth runs as a Convex component and exposes HTTP endpoints
/// under `/api/auth/`. This client communicates with those endpoints
/// directly — no third-party Flutter SDK needed.
class BetterAuthClient {
  /// Creates a [BetterAuthClient] for the given Convex [baseUrl].
  ///
  /// Optionally provide a custom [httpClient] for testing or proxy use.
  BetterAuthClient({
    required String baseUrl,
    http.Client? httpClient,
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null;

  /// The Convex deployment URL (e.g. "https://your-app.convex.cloud").
  final String baseUrl;
  final http.Client _http;
  final bool _ownsHttp;

  static String _normalizeBaseUrl(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        uri.scheme.isEmpty ||
        uri.host.isEmpty ||
        !const <String>{'http', 'https'}.contains(uri.scheme)) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be an absolute Convex HTTP URL with http or https scheme',
      );
    }
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be a Convex deployment origin without path, query, or fragment',
      );
    }
    return uri.replace(path: '', query: null, fragment: null).toString();
  }

  String get _siteUrl {
    final uri = Uri.parse(baseUrl);
    final host = uri.host;
    if (host.endsWith('.convex.cloud')) {
      return uri
          .replace(
            host: host.replaceFirst('.convex.cloud', '.convex.site'),
            path: '',
            query: null,
            fragment: null,
          )
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
    await _post('/api/auth/sign-in/magic-link', {
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
      throw BetterAuthException(
        'Magic link verification failed '
        '(status ${response.statusCode})$detail',
      );
    }

    final body = _decodeObjectBody(
      '/api/auth/magic-link/verify',
      response,
    );
    final user = _asObject(body['user']);
    final sessionToken = _extractSessionToken(response, body);

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
    final response = await _http.get(uri, headers: {
      'Authorization': 'Bearer $sessionToken',
    });

    if (response.statusCode == 401 || response.statusCode == 403) {
      return null;
    }
    if (response.statusCode != 200) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic>) {
          final message = body['message'];
          if (message is String && message.isNotEmpty) {
            detail = ': $message';
          }
        }
      } catch (_) {}
      throw BetterAuthException(
        'Better Auth get-session failed '
        '(status ${response.statusCode})$detail',
        retryable: response.statusCode >= 500,
      );
    }

    final body = _decodeObjectBody('/api/auth/get-session', response);
    final session = _asObject(body['session']);
    final user = _asObject(body['user']);
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

    final body = _decodeObjectBody(path, response);
    final user = _asObject(body['user']);

    // Always extract the session token for persistence.
    final sessionToken = _extractSessionToken(response, body);

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
      throw BetterAuthSessionExpiredException(
        'Failed to fetch Convex token (status ${response.statusCode}).',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const BetterAuthSessionExpiredException(
        'Convex token endpoint returned no token.',
      );
    }

    final token = decoded is Map<String, dynamic> ? decoded['token'] : null;
    if (token is! String || token.isEmpty) {
      throw const BetterAuthSessionExpiredException(
        'Convex token endpoint returned no token.',
      );
    }
    return token;
  }

  String _extractSessionToken(
    http.Response response, [
    Map<String, dynamic>? body,
  ]) {
    // Prefer the `set-auth-token` header (set by the Bearer plugin).
    // This is the official approach for mobile/API clients.
    final header = response.headers['set-auth-token'];
    if (header != null && header.isNotEmpty) {
      return header;
    }

    final bodyToken = body?['token'];
    if (bodyToken is String && bodyToken.isNotEmpty) {
      return bodyToken;
    }

    // Fallback: extract from set-cookie. Browsers never expose Set-Cookie to
    // Dart/JavaScript, so this path is native/test HTTP only.
    final fromCookie = _extractCookieValue(
      response,
      'better-auth.session_token',
    );
    if (fromCookie != null) {
      return fromCookie;
    }

    throw BetterAuthException(
      'Better Auth did not return a session token '
      '(status ${response.statusCode}). '
      'Mobile and desktop clients need the bearer() plugin to expose '
      'set-auth-token. Flutter web clients must also configure CORS with '
      'Access-Control-Expose-Headers: set-auth-token; browsers cannot read '
      'Set-Cookie. If your endpoint returns a JSON token, it must be a '
      'non-empty string field named "token".',
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
    for (final part in raw.split(RegExp(r',\s*(?=[^=;,\s]+=)'))) {
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
      throw BetterAuthException(
        'Better Auth request to $path failed '
        '(status ${response.statusCode})$detail',
      );
    }
    _throwIfErrorBody(path, response.body);
    return response;
  }

  void _throwIfErrorBody(String path, String bodyText) {
    if (bodyText.isEmpty) {
      return;
    }
    try {
      final body = jsonDecode(bodyText);
      if (body is! Map<String, dynamic>) {
        return;
      }
      final code = body['code'];
      if (code is! String || code.isEmpty) {
        return;
      }
      final error = body['error'];
      final message = body['message'];
      final detail = switch ((error, message)) {
        (final String error, final String message) when message.isNotEmpty =>
          '$error: $message',
        (final String error, _) when error.isNotEmpty => error,
        (_, final String message) when message.isNotEmpty => message,
        _ => code,
      };
      throw BetterAuthException(
        'Better Auth request to $path failed: $detail',
        data: body,
      );
    } on FormatException {
      return;
    }
  }

  /// Returns [value] as a string-keyed map, or `null` when it is absent or not
  /// a JSON object. Keeps a malformed nested `user`/`session` field from
  /// throwing a raw `TypeError` instead of a [BetterAuthException].
  static Map<String, dynamic>? _asObject(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    return null;
  }

  Map<String, dynamic> _decodeObjectBody(String path, http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw BetterAuthException(
        'Better Auth response from $path was not valid JSON '
        '(status ${response.statusCode}).',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw BetterAuthException(
        'Better Auth response from $path was not a JSON object '
        '(status ${response.statusCode}).',
      );
    }
    return decoded;
  }
}
