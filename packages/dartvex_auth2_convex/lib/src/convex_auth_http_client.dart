import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart'
    show convexToJson, createDefaultHttpClient, dartvexVersion, jsonToConvex;
import 'package:http/http.dart' as http;

import 'convex_auth_exception.dart';

/// Calls Convex mutations over the deployment's HTTP API
/// (`POST <deploymentUrl>/api/mutation`), without authentication.
///
/// The session provider refreshes and revokes sessions through this client
/// rather than the WebSocket: while the Convex client waits for a new token
/// its socket is paused, so a refresh sent over it could never complete. The
/// official `@convex-dev/auth` client does the same with `ConvexHttpClient`.
///
/// It can also call the auth mutations that do not return a session, such as
/// `signUpWithEmailPassword` or `startPasswordRecovery`.
///
/// Failures throw a [ConvexAuthException]: `retryable: true` for HTTP 5xx
/// and 429 responses, network and TLS errors, and timeouts.
class ConvexAuthHttpClient {
  /// Creates a client for the deployment at [deploymentUrl] (for example
  /// `https://your-deployment.convex.cloud`, the same URL as the
  /// `ConvexClient`).
  ///
  /// Credentials and refresh tokens travel in these requests, so a plain
  /// `http://` origin is only accepted for the local machine (`localhost`,
  /// a loopback address, or `10.0.2.2`, the Android emulator's alias of the
  /// host). Pass `allowInsecureHttp: true` to accept any other `http://`
  /// origin, for example a development backend on your local network; never
  /// do so in a released app.
  ///
  /// Pass [httpClient] to use your own `package:http` client; it is then not
  /// closed by [close].
  ConvexAuthHttpClient({
    required String deploymentUrl,
    http.Client? httpClient,
    this.requestTimeout = defaultRequestTimeout,
    this.clientId = 'dartvex-$dartvexVersion',
    bool allowInsecureHttp = false,
  })  : deploymentUrl = _normalizeOrigin(deploymentUrl, allowInsecureHttp),
        _http = httpClient ?? createDefaultHttpClient(),
        _ownsHttp = httpClient == null;

  /// Default per-request timeout.
  static const Duration defaultRequestTimeout = Duration(seconds: 30);

  /// HTTP status the Convex API uses for a function that threw.
  static const int _udfFailedStatus = 560;

  /// The Convex deployment origin.
  final String deploymentUrl;

  /// Timeout applied to every request, or `null` for none.
  final Duration? requestTimeout;

  /// Sent as the `Convex-Client` header.
  final String clientId;

  final http.Client _http;
  final bool _ownsHttp;

  static String _normalizeOrigin(String value, bool allowInsecureHttp) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        !const <String>{'http', 'https'}.contains(uri.scheme) ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(
        value,
        'deploymentUrl',
        'must be a Convex deployment origin such as '
            'https://your-deployment.convex.cloud',
      );
    }
    if (uri.scheme == 'http' &&
        !allowInsecureHttp &&
        !_isLocalMachine(uri.host)) {
      throw ArgumentError.value(
        value,
        'deploymentUrl',
        'must use https: credentials and refresh tokens would be sent in '
            'clear text. Plain http is accepted for localhost only; pass '
            'allowInsecureHttp: true for a development backend on another '
            'host',
      );
    }
    return uri.replace(path: '', query: null, fragment: null).toString();
  }

  /// Whether [host] is this machine: `localhost`, a loopback address, or the
  /// Android emulator's alias of the host loopback.
  static bool _isLocalMachine(String host) {
    final lower = host.toLowerCase();
    return lower == 'localhost' ||
        lower.endsWith('.localhost') ||
        lower == '::1' ||
        lower == '10.0.2.2' ||
        RegExp(r'^127(\.\d{1,3}){3}$').hasMatch(lower);
  }

  /// Runs the mutation at [path] (for example `auth:refreshSession`) with
  /// [args] and returns its decoded result.
  Future<Object?> mutation(
    String path, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) async {
    final uri = Uri.parse('$deploymentUrl/api/mutation');
    final body = jsonEncode(<String, Object?>{
      'path': path,
      'format': 'convex_encoded_json',
      'args': <Object?>[convexToJson(args)],
    });
    final response = await _post(uri, body, path);

    if (response.statusCode != _udfFailedStatus &&
        (response.statusCode < 200 || response.statusCode >= 300)) {
      final status = response.statusCode;
      // The body is left out: a gateway or the deployment may echo the
      // request (credentials, a refresh token) in it. Only the short error
      // code of the Convex API's `{code, message}` body is kept.
      final code = _apiErrorCode(response.body);
      throw ConvexAuthException(
        'Convex mutation $path failed with HTTP $status'
        '${code == null ? '' : ' ($code)'}.',
        retryable: status >= 500 || status == 429 || status == 408,
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw ConvexAuthException(
        'Convex mutation $path returned a non-JSON response '
        '(HTTP ${response.statusCode}).',
        retryable: true,
      );
    }
    if (decoded is! Map) {
      throw ConvexAuthException(
        'Convex mutation $path returned an unexpected response.',
      );
    }
    final logLines = switch (decoded['logLines']) {
      final List<Object?> lines => lines.whereType<String>().toList(),
      _ => const <String>[],
    };
    switch (decoded['status']) {
      case 'success':
        return jsonToConvex(decoded['value']);
      case 'error':
        final message = decoded['errorMessage'];
        final errorData = decoded['errorData'];
        // The server's text stays out of the message: it can quote
        // arguments. It is available as `serverMessage` and `logLines`.
        throw ConvexAuthException(
          'Convex mutation $path threw on the server.',
          data: errorData == null ? null : jsonToConvex(errorData),
          logLines: logLines,
          statusCode: response.statusCode,
          serverMessage:
              message is String && message.isNotEmpty ? message : null,
        );
      default:
        throw ConvexAuthException(
          'Convex mutation $path returned an unexpected response.',
        );
    }
  }

  /// Closes the underlying HTTP client (only if this client created it).
  void close() {
    if (_ownsHttp) {
      _http.close();
    }
  }

  Future<http.Response> _post(Uri uri, String body, String path) async {
    // Completed when the timeout fires: bounding only the wait would leave the
    // request running (and possibly minting a session nobody receives).
    final abort = Completer<void>();
    final request =
        http.AbortableRequest('POST', uri, abortTrigger: abort.future)
          ..headers.addAll(<String, String>{
            'Content-Type': 'application/json',
            'Convex-Client': clientId,
          })
          ..body = body;

    Future<http.Response> run() async =>
        http.Response.fromStream(await _http.send(request));

    final timeout = requestTimeout;
    try {
      return timeout == null ? await run() : await run().timeout(timeout);
    } on TimeoutException {
      if (!abort.isCompleted) {
        abort.complete();
      }
      throw ConvexAuthException(
        'Convex mutation $path timed out'
        '${timeout == null ? '' : ' after ${timeout.inMilliseconds} ms'}.',
        retryable: true,
      );
    } on http.ClientException catch (error) {
      // A transport error of the HTTP client (no response was read): its
      // text describes the connection, not the request or response body.
      throw ConvexAuthException(
        'Convex mutation $path failed: ${error.message}',
        retryable: true,
      );
    } on ConvexAuthException {
      rethrow;
    } on Exception catch (error) {
      // Transport failures the platform client does not wrap in a
      // ClientException, such as a TLS handshake failure on the IO client.
      throw ConvexAuthException(
        'Convex mutation $path failed: $error',
        retryable: true,
      );
    }
  }

  /// The `code` of a Convex API error body (`{"code": "...", "message":
  /// "..."}`), when it is a short identifier.
  static String? _apiErrorCode(String body) {
    if (body.length > 4096) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      final code = decoded is Map ? decoded['code'] : null;
      if (code is String && RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(code)) {
        return code;
      }
    } on FormatException {
      // Not JSON: no code.
    }
    return null;
  }
}
