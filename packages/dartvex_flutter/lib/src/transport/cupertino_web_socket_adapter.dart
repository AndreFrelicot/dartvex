import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:dartvex/dartvex.dart';
import 'package:meta/meta.dart';
import 'package:web_socket/web_socket.dart';

import 'cupertino_session_web_socket.dart';

/// Installs the NSURLSession-backed WebSocket and HTTP transports as the
/// process-wide defaults on iOS and macOS. No-op elsewhere.
///
/// Called automatically by `DartvexFlutterPlugin.registerWith()` before
/// `main()` on Apple platforms. Covers every network path the SDK uses:
/// the sync WebSocket, storage uploads, and auth endpoints all travel the
/// system network stack instead of raw `dart:io` sockets. Apps can opt back
/// into `dart:io` by resetting [defaultWebSocketAdapterOverride] and
/// [defaultHttpClientFactory] to `null`, or per client via
/// `ConvexClientConfig.adapterFactory` / explicit `httpClient` parameters,
/// which always take precedence over the defaults.
void installCupertinoTransport() {
  if (!Platform.isIOS && !Platform.isMacOS) {
    return;
  }
  defaultWebSocketAdapterOverride =
      (String clientId) => CupertinoWebSocketAdapter(clientId: clientId);
  defaultHttpClientFactory = CupertinoClient.defaultSessionConfiguration;
}

/// Signature of the function that opens the underlying platform socket.
///
/// Injectable so contract tests can substitute a fake [WebSocket] without
/// touching NSURLSession (which is unavailable under `flutter test`).
typedef CupertinoWebSocketConnector = Future<WebSocket> Function(
  Uri url,
  String clientId,
);

Future<WebSocket> _defaultConnector(Uri url, String clientId) {
  final config = URLSessionConfiguration.defaultSessionConfiguration()
    ..httpAdditionalHeaders = <String, String>{'Convex-Client': clientId};
  // Session-owning variant rather than CupertinoWebSocket.connect: upstream
  // never invalidates the URLSession it creates per connect, which leaks a
  // native session on every reconnect attempt.
  return OwnedSessionCupertinoWebSocket.connect(url, config: config);
}

/// A [WebSocketAdapter] that transports Convex sync messages over an
/// NSURLSessionWebSocketTask (via `package:cupertino_http`) instead of raw
/// `dart:io` sockets.
///
/// NSURLSession is the same network path Safari and native apps use. Unlike
/// BSD sockets it is brokered by the system networking daemon, which makes it
/// immune to per-app socket policy glitches (`errno 65` blackholes observed
/// on some iOS devices with debug builds) and lets connections benefit from
/// the OS's proxy/Happy-Eyeballs handling.
///
/// Mirrors the lifecycle contract of the default `dart:io` adapter:
/// a failed in-flight connect rejects the [connect] future, the socket
/// reference is cleared before a close event is delivered, and frames from a
/// superseded socket never reach the sync layer.
class CupertinoWebSocketAdapter implements WebSocketAdapter {
  /// Creates an adapter advertising [clientId] to the Convex server via the
  /// `Convex-Client` header.
  CupertinoWebSocketAdapter({
    required this.clientId,
    @visibleForTesting CupertinoWebSocketConnector? connector,
  }) : _connector = connector ?? _defaultConnector;

  /// Identifier sent as the `Convex-Client` header to tag this client.
  final String clientId;

  final CupertinoWebSocketConnector _connector;
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast();

  WebSocket? _socket;
  int _connectGeneration = 0;

  @override
  Future<void> connect(String url) async {
    await close();
    final generation = ++_connectGeneration;
    // A connection failure rejects this future, as the adapter contract
    // requires: the sync layer must see a failed connect rather than a close
    // event that only ever surfaces mid-connect.
    final socket = await _connector(Uri.parse(url), clientId);
    if (generation != _connectGeneration) {
      // A newer connect() or close() superseded this attempt (for example
      // after a connect-timeout). Discard the late socket instead of leaking
      // it.
      unawaited(_closeSocketQuietly(socket));
      return;
    }
    _socket = socket;
    var closeEventEmitted = false;
    void emitClose(WebSocketCloseEvent event) {
      if (closeEventEmitted) {
        return;
      }
      closeEventEmitted = true;
      if (identical(_socket, socket)) {
        _socket = null;
      }
      if (!_closeController.isClosed) {
        _closeController.add(event);
      }
    }

    socket.events.listen(
      (WebSocketEvent event) {
        switch (event) {
          case TextDataReceived(:final text):
            // Drop frames from a socket that a later connect() or close() has
            // already superseded, mirroring the dart:io adapter: a stale
            // Transition reaching the sync layer would mismatch the reset
            // version and force a spurious reconnect.
            if (!identical(_socket, socket)) {
              return;
            }
            if (!_messagesController.isClosed) {
              _messagesController.add(text);
            }
          case BinaryDataReceived(:final data):
            if (!identical(_socket, socket)) {
              return;
            }
            if (!_messagesController.isClosed) {
              // allowMalformed: invalid UTF-8 in a binary frame must not
              // throw out of this listener as an uncaught zone error. The
              // replacement characters make the message fail JSON parsing
              // upstream instead, which drives the sync layer's
              // InvalidServerMessage reconnect.
              _messagesController.add(utf8.decode(data, allowMalformed: true));
            }
          case CloseReceived(:final code, :final reason):
            emitClose(
              WebSocketCloseEvent(
                code: code,
                reason: reason.isEmpty ? null : reason,
              ),
            );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!identical(_socket, socket)) {
          return;
        }
        emitClose(
          WebSocketCloseEvent(
            code: 1006,
            errorMessage: error.toString(),
          ),
        );
        unawaited(_closeSocketAfterStreamError(socket));
      },
      // The underlying stream always ends with a CloseReceived event; this is
      // a defensive fallback so a silently-ended stream still surfaces as a
      // close (emitClose dedupes).
      onDone: () => emitClose(const WebSocketCloseEvent()),
      cancelOnError: false,
    );
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeController.stream;

  @override
  void send(String message) {
    final socket = _socket;
    if (socket == null) {
      throw StateError('WebSocket is not connected');
    }
    try {
      socket.sendText(message);
    } on WebSocketConnectionClosed {
      throw StateError('WebSocket is not connected');
    }
  }

  @override
  Future<void> close() async {
    _connectGeneration++;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await _closeSocketQuietly(socket).timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
  }

  Future<void> _closeSocketQuietly(WebSocket socket) async {
    try {
      // 1000 (normal closure) is the closest NSURLSessionWebSocketTask gets
      // to dart:io's default close frame; closing without a code cancels the
      // task abruptly, which the server records as an abnormal disconnect.
      await socket.close(1000);
    } on WebSocketConnectionClosed {
      // Already closed.
    }
  }

  Future<void> _closeSocketAfterStreamError(WebSocket socket) async {
    try {
      await _closeSocketQuietly(socket);
    } catch (_) {
      // The stream error is already being reported to the sync layer as an
      // abnormal close. A best-effort cleanup failure must not escape the zone.
    }
  }

  @override
  bool get isConnected => _socket != null;
}
