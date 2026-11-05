import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart' show createDefaultHttpClient;
import 'package:http/http.dart' as http;

import 'better_auth_exception.dart';
import 'better_auth_session.dart';

/// HTTP client for Better Auth endpoints hosted on a Convex deployment.
///
/// Better Auth runs as a Convex component and exposes HTTP endpoints
/// under `/api/auth/` on the deployment's HTTP-actions origin
/// (`https://<deployment>.convex.site`). This client communicates with those
/// endpoints directly — no third-party Flutter SDK needed.
///
/// Every request is bearer-token based and never relies on cookies.
/// Transport failures (offline, DNS failure, reset connection) and request
/// timeouts are reported as a [BetterAuthException] with `retryable: true`.
class BetterAuthClient {
  /// Creates a [BetterAuthClient] for the given Convex [baseUrl].
  ///
  /// [baseUrl] is the Convex deployment URL you also give `ConvexClient`
  /// (`https://<deployment>.convex.cloud`). Auth requests go to the matching
  /// HTTP-actions origin, derived by replacing `.convex.cloud` with
  /// `.convex.site`. Any other host is used unchanged.
  ///
  /// Pass [siteUrl] when the HTTP-actions origin cannot be derived from
  /// [baseUrl]: custom domains, local backends (`npx convex dev` serves HTTP
  /// actions on a separate port, e.g. `http://127.0.0.1:3211`) and
  /// self-hosted deployments. Use the value of the deployment's
  /// `CONVEX_SITE_URL`. When set, [siteUrl] takes precedence over [baseUrl].
  ///
  /// Pass [basePath] when the server mounts Better Auth on a custom
  /// `basePath` (defaults to `/api/auth`, the `@convex-dev/better-auth`
  /// default).
  ///
  /// [requestTimeout] bounds every HTTP request (connect, send and response
  /// body). It defaults to 30 seconds; pass `null` to disable it. A timed-out
  /// request throws a retryable [BetterAuthException].
  ///
  /// Optionally provide a custom [httpClient] for testing or proxy use.
  BetterAuthClient({
    required String baseUrl,
    String? siteUrl,
    String basePath = defaultBasePath,
    http.Client? httpClient,
    this.requestTimeout = defaultRequestTimeout,
  })  : baseUrl = _normalizeOrigin(baseUrl, 'baseUrl'),
        siteUrl = siteUrl != null
            ? _normalizeOrigin(siteUrl, 'siteUrl')
            : _deriveSiteUrl(_normalizeOrigin(baseUrl, 'baseUrl')),
        basePath = _normalizeBasePath(basePath),
        _http = httpClient ?? createDefaultHttpClient(),
        _ownsHttp = httpClient == null;

  /// Default Better Auth mount path used by `@convex-dev/better-auth`.
  static const String defaultBasePath = '/api/auth';

  /// Default per-request timeout.
  static const Duration defaultRequestTimeout = Duration(seconds: 30);

  /// The Convex deployment URL (e.g. "https://your-deployment.convex.cloud").
  final String baseUrl;

  /// The HTTP-actions origin that receives Better Auth requests
  /// (e.g. "https://your-deployment.convex.site").
  final String siteUrl;

  /// The path Better Auth is mounted on (default `/api/auth`).
  final String basePath;

  /// Timeout applied to every HTTP request, or `null` for none.
  final Duration? requestTimeout;

  final http.Client _http;
  final bool _ownsHttp;

  static const String _sessionCookieName = 'better-auth.session_token';
  static const String _convexJwtCookieName = 'better-auth.convex_jwt';

  static String _normalizeOrigin(String value, String name) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.isEmpty ||
        uri.host.isEmpty ||
        !const <String>{'http', 'https'}.contains(uri.scheme)) {
      throw ArgumentError.value(
        value,
        name,
        'must be an absolute Convex HTTP URL with http or https scheme',
      );
    }
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(
        value,
        name,
        'must be a Convex deployment origin without path, query, or fragment',
      );
    }
    return uri.replace(path: '', query: null, fragment: null).toString();
  }

  static String _deriveSiteUrl(String baseUrl) {
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

  static String _normalizeBasePath(String basePath) {
    final trimmed = basePath.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !trimmed.startsWith('/') ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        trimmed.split('/').contains('..')) {
      throw ArgumentError.value(
        basePath,
        'basePath',
        'must be an absolute path such as /api/auth',
      );
    }
    var normalized = trimmed;
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  /// Closes the underlying HTTP client (only if we created it).
  void close() {
    if (_ownsHttp) {
      _http.close();
    }
  }

  /// Signs up a new user with email and password.
  ///
  /// Throws [BetterAuthEmailVerificationRequiredException] when Better Auth
  /// creates the account without starting a session (email verification
  /// required, or `autoSignIn: false`).
  Future<BetterAuthSession> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    return _authenticate(
        '/sign-up/email',
        {
          'name': name,
          'email': email,
          'password': password,
        },
        fallbackEmail: email);
  }

  /// Signs in an existing user with email and password.
  ///
  /// Throws [BetterAuthTwoFactorRequiredException] when the user has
  /// two-factor authentication enabled. A wrong password surfaces as a
  /// [BetterAuthException] whose [BetterAuthException.code] is
  /// `INVALID_EMAIL_OR_PASSWORD`; an unverified email as `EMAIL_NOT_VERIFIED`.
  Future<BetterAuthSession> signIn({
    required String email,
    required String password,
  }) async {
    return _authenticate(
        '/sign-in/email',
        {
          'email': email,
          'password': password,
        },
        fallbackEmail: email);
  }

  /// Sends a password reset email.
  ///
  /// Better Auth's reset link redirects to [redirectTo] with a `?token=`
  /// query parameter; pass that token to [resetPassword]. Custom-scheme
  /// redirects must be listed in the server's `trustedOrigins`.
  Future<void> forgotPassword({
    required String email,
    String? redirectTo,
  }) async {
    await _post('/request-password-reset', {
      'email': email,
      if (redirectTo != null) 'redirectTo': redirectTo,
    });
  }

  /// Resets the password using a token from the reset email.
  Future<void> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    await _post('/reset-password', {
      'token': token,
      'newPassword': newPassword,
    });
  }

  /// Sends a magic link email.
  ///
  /// Better Auth's default emailed link opens `/magic-link/verify` in a
  /// browser, which consumes the token there and redirects to [callbackURL]
  /// **without** the token. For [verifyMagicLink] to work in a native app,
  /// the server's `magicLink({ sendMagicLink })` callback must email a deep
  /// link built from the `token` it receives (for example
  /// `myapp://auth/magic-link?token=...`). [callbackURL] is only useful for
  /// browser flows; any custom scheme it uses must be in `trustedOrigins`.
  Future<void> sendMagicLink({
    required String email,
    String? callbackURL,
  }) async {
    await _post('/sign-in/magic-link', {
      'email': email,
      if (callbackURL != null) 'callbackURL': callbackURL,
    });
  }

  /// Verifies a magic link token and returns a session.
  ///
  /// The token is single-use. An invalid, expired or already used token
  /// throws a [BetterAuthException] whose [BetterAuthException.code] is
  /// Better Auth's error code (`INVALID_TOKEN`, `EXPIRED_TOKEN`,
  /// `ATTEMPTS_EXCEEDED`, ...).
  ///
  /// To authenticate an existing `ConvexClientWithAuth` with the returned
  /// session, pass it to `ConvexBetterAuthProvider.adoptSession` and then
  /// call `loginFromCache()` on the wrapper.
  Future<BetterAuthSession> verifyMagicLink({
    required String token,
  }) async {
    final path = '$basePath/magic-link/verify';
    final uri = _endpoint('/magic-link/verify').replace(
      queryParameters: {'token': token},
    );
    // Better Auth reports verification failures as a redirect to
    // `<errorCallbackURL>?error=CODE`; do not follow it so the code survives.
    final reply = await _send('GET', uri, followRedirects: false);
    final response = reply.response;

    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      final location = response.headers['location'];
      throw _magicLinkRedirectError(
        status,
        location == null ? null : Uri.tryParse(location),
      );
    }
    // Browsers always follow redirects; recover the code from the final URL.
    final finalUrl = reply.url;
    if (finalUrl != null &&
        finalUrl.path != uri.path &&
        finalUrl.queryParameters['error'] != null) {
      throw _magicLinkRedirectError(status, finalUrl);
    }

    if (status != 200) {
      throw _statusError('Magic link verification failed', response);
    }

    final body = _decodeObjectBody(path, response);
    final user = _asObject(body['user']);
    final sessionToken = _extractSessionToken(response, body);

    final cookieJwt = _extractCookieValue(response, _convexJwtCookieName);
    final convexJwt = cookieJwt ?? await _fetchConvexToken(sessionToken);
    return BetterAuthSession(
      token: convexJwt,
      sessionToken: sessionToken,
      userId: _stringField(user, 'id'),
      email: _stringField(user, 'email'),
      name: _nullableStringField(user, 'name'),
    );
  }

  /// Signs out the current session.
  Future<void> signOut({required String sessionToken}) async {
    await _post(
      '/sign-out',
      {},
      bearerToken: sessionToken,
    );
  }

  /// Gets the current session, or `null` if not authenticated.
  ///
  /// Returns `null` when Better Auth reports no session for [sessionToken]
  /// (HTTP 200 with a JSON `null` body, or 401/403), i.e. the session expired
  /// or was revoked. Other failures throw a [BetterAuthException]; 5xx/429
  /// responses and network errors are `retryable`.
  Future<BetterAuthSession?> getSession({
    required String sessionToken,
  }) async {
    final path = '$basePath/get-session';

    // Use Bearer auth (requires the `bearer()` plugin on the server).
    // This is the official approach for mobile/API clients without cookies.
    final reply = await _send('GET', _endpoint('/get-session'), headers: {
      'Authorization': 'Bearer $sessionToken',
    });
    final response = reply.response;

    if (response.statusCode == 401 || response.statusCode == 403) {
      return null;
    }
    if (response.statusCode != 200) {
      throw _statusError('Better Auth get-session failed', response);
    }

    final decoded = _decodeJsonBody(path, response);
    // Better Auth answers a missing, unknown or expired session with HTTP 200
    // and the JSON body `null`.
    if (decoded == null) {
      return null;
    }
    final body = _requireObject(path, response, decoded);
    final session = _asObject(body['session']);
    final user = _asObject(body['user']);
    if (session == null || user == null) return null;

    // The Convex plugin refreshes the JWT cookie on get-session responses for
    // a live session; use it to skip the /convex/token round-trip.
    final cookieJwt = _extractCookieValue(response, _convexJwtCookieName);
    final convexJwt = cookieJwt ?? await _fetchConvexToken(sessionToken);
    return BetterAuthSession(
      token: convexJwt,
      sessionToken: sessionToken,
      userId: _stringField(user, 'id'),
      email: _stringField(user, 'email'),
      name: _nullableStringField(user, 'name'),
    );
  }

  /// Common sign-up / sign-in flow: POST → extract session token → fetch JWT.
  Future<BetterAuthSession> _authenticate(
    String route,
    Map<String, dynamic> requestBody, {
    required String fallbackEmail,
  }) async {
    final path = '$basePath$route';
    final response = await _post(route, requestBody);

    final body = _decodeObjectBody(path, response);
    final user = _asObject(body['user']);

    if (body['twoFactorRedirect'] == true) {
      throw BetterAuthTwoFactorRequiredException(
        'Better Auth requires a second factor to finish signing in '
        '($path). Two-factor verification is not supported by '
        'BetterAuthClient yet.',
        data: body,
      );
    }
    if (body.containsKey('token') &&
        body['token'] == null &&
        user != null &&
        !_hasSessionCredential(response)) {
      throw BetterAuthEmailVerificationRequiredException(
        'Better Auth accepted the request to $path but did not start a '
        'session (token: null). The email address must be verified '
        '(requireEmailVerification) or autoSignIn is disabled; ask the user '
        'to verify their email, then sign in.',
        data: body,
      );
    }

    // Always extract the session token for persistence.
    final sessionToken = _extractSessionToken(response, body);

    // Try the Convex JWT from cookies first (avoids a second round-trip).
    // Recent @convex-dev/better-auth versions expire this cookie on sign-in
    // and sign-up instead; an expired cookie counts as absent.
    final cookieJwt = _extractCookieValue(response, _convexJwtCookieName);
    final convexJwt = cookieJwt ?? await _fetchConvexToken(sessionToken);

    return BetterAuthSession(
      token: convexJwt,
      sessionToken: sessionToken,
      userId: _stringField(user, 'id'),
      email: _stringField(user, 'email', fallback: fallbackEmail),
      name: _nullableStringField(user, 'name'),
    );
  }

  /// Fetches the Convex JWT from the Better Auth `/convex/token` endpoint.
  Future<String> _fetchConvexToken(String sessionToken) async {
    final reply = await _send('GET', _endpoint('/convex/token'), headers: {
      'Authorization': 'Bearer $sessionToken',
    });
    final response = reply.response;

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw BetterAuthSessionExpiredException(
        'Failed to fetch Convex token (status ${response.statusCode}).',
      );
    }
    if (response.statusCode != 200) {
      throw _statusError('Failed to fetch Convex token', response);
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

  Uri _endpoint(String route) => Uri.parse('$siteUrl$basePath$route');

  /// Sends one request with the configured timeout, mapping transport
  /// failures to retryable [BetterAuthException]s.
  ///
  /// Returns the response and, when the platform client reports it, the
  /// final URL after redirects.
  Future<({http.Response response, Uri? url})> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    bool followRedirects = true,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = followRedirects;
    if (headers != null) {
      request.headers.addAll(headers);
    }
    if (body != null) {
      request.body = body;
    }

    Future<({http.Response response, Uri? url})> run() async {
      final streamed = await _http.send(request);
      final url = switch (streamed) {
        http.BaseResponseWithUrl(:final url) => url,
        _ => null,
      };
      final response = await http.Response.fromStream(streamed);
      return (response: response, url: url);
    }

    // Report the path only: the query of some endpoints carries tokens.
    final path = uri.path;
    final timeout = requestTimeout;
    try {
      return timeout == null ? await run() : await run().timeout(timeout);
    } on TimeoutException {
      throw BetterAuthException(
        'Better Auth request to $path timed out'
        '${timeout == null ? '' : ' after ${timeout.inMilliseconds} ms'}.',
        retryable: true,
      );
    } on http.ClientException catch (error) {
      throw BetterAuthException(
        'Better Auth request to $path failed: ${error.message}',
        retryable: true,
      );
    }
  }

  static bool _isRetryableStatus(int statusCode) =>
      statusCode >= 500 || statusCode == 429;

  /// Builds the exception for a non-success HTTP status, keeping the decoded
  /// error body (Better Auth's `{code, message}`) as `data`.
  static BetterAuthException _statusError(
    String prefix,
    http.Response response,
  ) {
    final body = _tryDecodeObject(response.body);
    final message = body?['message'];
    final detail = message is String && message.isNotEmpty ? ': $message' : '';
    return BetterAuthException(
      '$prefix (status ${response.statusCode})$detail',
      data: body,
      retryable: _isRetryableStatus(response.statusCode),
    );
  }

  static BetterAuthException _magicLinkRedirectError(int status, Uri? target) {
    final code = target?.queryParameters['error'];
    final description = target?.queryParameters['error_description'];
    final detail = code == null || code.isEmpty
        ? ''
        : ': $code${description == null || description.isEmpty ? '' : ' ($description)'}';
    return BetterAuthException(
      'Magic link verification failed (status $status)$detail',
      data: code == null || code.isEmpty
          ? null
          : <String, dynamic>{
              'code': code,
              if (description != null && description.isNotEmpty)
                'message': description,
            },
    );
  }

  static Map<String, dynamic>? _tryDecodeObject(String bodyText) {
    try {
      return _asObject(jsonDecode(bodyText));
    } on FormatException {
      return null;
    }
  }

  /// Whether the response carries a session token Better Auth issued through
  /// a header or a live cookie (the JSON `token` field is checked separately).
  bool _hasSessionCredential(http.Response response) {
    final header = response.headers['set-auth-token'];
    if (header != null && header.isNotEmpty) {
      return true;
    }
    return _extractCookieValue(response, _sessionCookieName) != null;
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
    final fromCookie = _extractCookieValue(response, _sessionCookieName);
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

  /// Extracts a live cookie value from `set-cookie` headers by suffix match.
  ///
  /// Cookie names may be prefixed (e.g. `__Secure-better-auth.session_token`),
  /// so we match on the suffix. When a cookie is set several times, the last
  /// occurrence wins, as in a browser. A cookie that is being deleted (empty
  /// value, `Max-Age` <= 0, or an `Expires` date in the past) counts as
  /// absent and yields `null`.
  String? _extractCookieValue(http.Response response, String nameSuffix) {
    // `package:http` folds multiple set-cookie headers into a
    // comma-separated string.
    final raw = response.headers['set-cookie'];
    if (raw == null) return null;
    String? result;
    for (final part in raw.split(RegExp(r',\s*(?=[^=;,\s]+=)'))) {
      final cookie = part.trim();
      final eqIndex = cookie.indexOf('=');
      if (eqIndex < 0) continue;
      final name = cookie.substring(0, eqIndex).trim();
      if (!name.endsWith(nameSuffix)) continue;
      final segments = cookie.substring(eqIndex + 1).split(';');
      final value = _decodeCookieValue(segments.first.trim());
      result =
          value.isEmpty || _isExpiredCookie(segments.skip(1)) ? null : value;
    }
    return result;
  }

  static String _decodeCookieValue(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    } on FormatException {
      return value;
    }
  }

  /// Whether the cookie attributes delete the cookie. `Max-Age` takes
  /// precedence over `Expires` (RFC 6265 §5.3).
  static bool _isExpiredCookie(Iterable<String> attributes) {
    int? maxAge;
    DateTime? expires;
    for (final attribute in attributes) {
      final trimmed = attribute.trim();
      final eqIndex = trimmed.indexOf('=');
      final key =
          (eqIndex < 0 ? trimmed : trimmed.substring(0, eqIndex)).trim();
      final value = eqIndex < 0 ? '' : trimmed.substring(eqIndex + 1).trim();
      switch (key.toLowerCase()) {
        case 'max-age':
          maxAge = int.tryParse(value);
        case 'expires':
          expires = _parseCookieDate(value);
      }
    }
    if (maxAge != null) {
      return maxAge <= 0;
    }
    if (expires != null) {
      return !expires.isAfter(DateTime.now().toUtc());
    }
    return false;
  }

  static const List<String> _months = <String>[
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];

  /// Parses an HTTP cookie date such as `Thu, 01 Jan 1970 00:00:00 GMT`
  /// (also the legacy `01-Jan-70` form). Returns `null` when unparseable.
  static DateTime? _parseCookieDate(String value) {
    final match = RegExp(
      r'(\d{1,2})[\s-]+([A-Za-z]{3})[A-Za-z]*[\s-]+(\d{2,4})\s+'
      r'(\d{1,2}):(\d{2}):(\d{2})',
    ).firstMatch(value);
    if (match == null) {
      return null;
    }
    final month = _months.indexOf(match.group(2)!.toLowerCase());
    if (month < 0) {
      return null;
    }
    var year = int.parse(match.group(3)!);
    if (year < 100) {
      year += year >= 70 ? 1900 : 2000;
    }
    return DateTime.utc(
      year,
      month + 1,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  Future<http.Response> _post(
    String route,
    Map<String, dynamic> body, {
    String? bearerToken,
  }) async {
    final path = '$basePath$route';
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
    };
    final reply = await _send(
      'POST',
      _endpoint(route),
      headers: headers,
      body: jsonEncode(body),
    );
    final response = reply.response;

    if (response.statusCode != 200) {
      throw _statusError('Better Auth request to $path failed', response);
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

  static String _stringField(
    Map<String, dynamic>? value,
    String key, {
    String fallback = '',
  }) {
    final field = value?[key];
    return field is String ? field : fallback;
  }

  static String? _nullableStringField(Map<String, dynamic>? value, String key) {
    final field = value?[key];
    return field is String ? field : null;
  }

  static Object? _decodeJsonBody(String path, http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw BetterAuthException(
        'Better Auth response from $path was not valid JSON '
        '(status ${response.statusCode}).',
      );
    }
  }

  static Map<String, dynamic> _requireObject(
    String path,
    http.Response response,
    Object? decoded,
  ) {
    if (decoded is! Map<String, dynamic>) {
      throw BetterAuthException(
        'Better Auth response from $path was not a JSON object '
        '(status ${response.statusCode}).',
      );
    }
    return decoded;
  }

  static Map<String, dynamic> _decodeObjectBody(
    String path,
    http.Response response,
  ) {
    return _requireObject(path, response, _decodeJsonBody(path, response));
  }
}
