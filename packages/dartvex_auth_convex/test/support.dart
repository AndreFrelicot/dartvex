import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const deploymentUrl = 'https://test-app.convex.cloud';

/// A token bundle as returned by Convex Auth.
Map<String, Object> bundle(String id, {String userId = 'u1'}) =>
    <String, Object>{
      'accessToken': 'jwt_$id',
      'refreshToken': 'rt_$id',
      'refreshTokenExpiresAt': 1893456000000,
      'userId': userId,
    };

Map<String, Object> complete(String id) =>
    <String, Object>{'status': 'complete', 'tokens': bundle(id)};

Map<String, Object> rotated(String id) =>
    <String, Object>{'kind': 'rotated', 'tokens': bundle(id)};

const Map<String, Object> noSession = <String, Object>{'kind': 'noSession'};

/// One `POST /api/mutation` received by [FakeConvexAuthServer].
class MutationCall {
  MutationCall(this.path, this.args);

  final String path;
  final Map<String, dynamic> args;

  @override
  String toString() => 'MutationCall($path, $args)';
}

/// Handles a mutation: returns the function's value, or throws an
/// [http.Response] to send it as is.
typedef MutationHandler = FutureOr<Object?> Function(MutationCall call);

/// Mocked Convex HTTP API answering `POST /api/mutation`.
class FakeConvexAuthServer {
  final List<MutationCall> calls = <MutationCall>[];
  final Map<String, MutationHandler> handlers = <String, MutationHandler>{};

  List<MutationCall> callsTo(String path) =>
      calls.where((call) => call.path == path).toList();

  late final http.Client httpClient = MockClient((request) async {
    if (request.method != 'POST' || request.url.path != '/api/mutation') {
      return http.Response('Not found', 404);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final call = MutationCall(
      body['path'] as String,
      ((body['args'] as List).single as Map).cast<String, dynamic>(),
    );
    calls.add(call);
    final handler = handlers[call.path];
    if (handler == null) {
      return _json(<String, Object?>{
        'status': 'error',
        'errorMessage': 'Could not find public function for ${call.path}',
        'logLines': <String>[],
      }, 404);
    }
    try {
      final value = await handler(call);
      return _json(<String, Object?>{
        'status': 'success',
        'value': value,
        'logLines': <String>[],
      });
    } on http.Response catch (response) {
      return response;
    }
  });

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});
}

Future<void> waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed >= timeout) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Minimal in-memory [WebSocketAdapter] recording client messages.
class FakeWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeEvents =
      StreamController<WebSocketCloseEvent>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool _connected = false;
  int _ts = 0;

  @override
  Future<void> connect(String url) async {
    _connected = true;
    _ts = 0;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Fake socket is disconnected');
    }
    sent.add(jsonDecode(message) as Map<String, dynamic>);
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeEvents.stream;

  @override
  Future<void> close() async {
    if (!_connected) {
      return;
    }
    _connected = false;
    _closeEvents.add(WebSocketCloseEvent());
  }

  @override
  bool get isConnected => _connected;

  int get sentCount => sent.length;

  Future<Map<String, dynamic>> waitForAuthenticate(
    bool Function(Map<String, dynamic> message) where, {
    int after = 0,
  }) async {
    bool matches(Map<String, dynamic> message) =>
        message['type'] == 'Authenticate' && where(message);
    await waitUntil(
      () => sent.skip(after).any(matches),
      reason: 'Authenticate message',
    );
    return sent.skip(after).lastWhere(matches);
  }

  String _encodeTs(int value) {
    final bytes = List<int>.filled(8, 0);
    var remaining = value;
    for (var i = 0; i < 8; i++) {
      bytes[i] = remaining & 0xff;
      remaining >>= 8;
    }
    return base64.encode(bytes);
  }

  int get _lastAuthBaseVersion => sent.lastWhere(
      (message) => message['type'] == 'Authenticate')['baseVersion'] as int;

  /// Acknowledges the last Authenticate by advancing the identity version.
  void confirmAuth() {
    final base = _lastAuthBaseVersion;
    _messages.add(
      jsonEncode({
        'type': 'Transition',
        'startVersion': {
          'querySet': 0,
          'identity': base,
          'ts': _encodeTs(_ts),
        },
        'endVersion': {
          'querySet': 0,
          'identity': base + 1,
          'ts': _encodeTs(++_ts),
        },
        'modifications': <Object>[],
      }),
    );
  }

  /// Rejects the last Authenticate, which makes the client fetch a fresh
  /// token through the provider's loginFromCache.
  void sendAuthError() {
    _messages.add(
      jsonEncode({
        'type': 'AuthError',
        'error': 'token rejected',
        'baseVersion': _lastAuthBaseVersion,
        'authUpdateAttempted': true,
      }),
    );
  }
}
