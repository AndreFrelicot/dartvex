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
  final StreamController<void> _closeController =
      StreamController<void>.broadcast();

  WebSocket? _socket;

  @override
  Future<void> connect(String url) async {
    await close();
    final socket = await WebSocket.connect(
      url,
      headers: <String, dynamic>{'Convex-Client': clientId},
    );
    _socket = socket;
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
        _socket = null;
        _closeController.add(null);
      },
      onError: (Object _) {
        _socket = null;
        _closeController.add(null);
      },
      cancelOnError: false,
    );
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<void> get closeEvents => _closeController.stream;

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
