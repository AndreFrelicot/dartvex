import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ws_interface.dart';

/// Creates the platform [WebSocketAdapter] backed by `dart:io` sockets.
///
/// Used by the Convex sync client on native (non-web) platforms; [clientId]
/// identifies this client to the server via the `Convex-Client` header.
WebSocketAdapter createWebSocketAdapter(String clientId) {
  return NativeWebSocketAdapter(clientId: clientId);
}

/// A [WebSocketAdapter] implementation that transports Convex sync messages
/// over a native `dart:io` [WebSocket] connection.
class NativeWebSocketAdapter implements WebSocketAdapter {
  /// Creates a [NativeWebSocketAdapter] that advertises [clientId] to the
  /// Convex server when connecting.
  NativeWebSocketAdapter({required this.clientId});

  /// Identifier sent as the `Convex-Client` header to tag this client.
  final String clientId;
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
    final socket = await WebSocket.connect(
      url,
      headers: <String, dynamic>{'Convex-Client': clientId},
    );
    if (generation != _connectGeneration) {
      // A newer connect() or close() superseded this attempt (for example after
      // a connect-timeout). Discard the late socket instead of leaking it.
      unawaited(socket.close());
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

    socket.listen(
      (dynamic event) {
        if (event is String) {
          if (!_messagesController.isClosed) {
            _messagesController.add(event);
          }
          return;
        }
        if (event is List<int>) {
          if (!_messagesController.isClosed) {
            _messagesController.add(utf8.decode(event));
          }
        }
      },
      onDone: () {
        emitClose(
          WebSocketCloseEvent(
            code: socket.closeCode,
            reason: socket.closeReason,
          ),
        );
      },
      onError: (Object error) {
        emitClose(
          WebSocketCloseEvent(
            code: socket.closeCode,
            reason: socket.closeReason,
            errorMessage: error.toString(),
          ),
        );
      },
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
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('WebSocket is not connected');
    }
    socket.add(message);
  }

  @override
  Future<void> close() async {
    _connectGeneration++;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close().timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
    }
  }

  @override
  bool get isConnected => _socket?.readyState == WebSocket.open;
}
