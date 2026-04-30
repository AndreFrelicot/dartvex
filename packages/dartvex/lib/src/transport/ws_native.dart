import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ws_interface.dart';

WebSocketAdapter createWebSocketAdapter(String clientId) {
  return NativeWebSocketAdapter(clientId: clientId);
}

class NativeWebSocketAdapter implements WebSocketAdapter {
  NativeWebSocketAdapter({required this.clientId});

  final String clientId;
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast();

  WebSocket? _socket;

  @override
  Future<void> connect(String url) async {
    await close();
    final socket = await WebSocket.connect(
      url,
      headers: <String, dynamic>{'Convex-Client': clientId},
    );
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
      _closeController.add(event);
    }

    socket.listen(
      (dynamic event) {
        if (event is String) {
          _messagesController.add(event);
          return;
        }
        if (event is List<int>) {
          _messagesController.add(utf8.decode(event));
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
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close();
    }
  }

  @override
  bool get isConnected => _socket?.readyState == WebSocket.open;
}
