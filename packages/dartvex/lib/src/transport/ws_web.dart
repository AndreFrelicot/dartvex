import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'ws_interface.dart';

WebSocketAdapter createWebSocketAdapter(String clientId) {
  return WebPlatformWebSocketAdapter();
}

class WebPlatformWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast();

  web.WebSocket? _socket;

  @override
  Future<void> connect(String url) async {
    await close();
    final socket = web.WebSocket(url);
    final completer = Completer<void>();
    _socket = socket;

    socket.onopen = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      final stringValue = (data as JSString?)?.toDart;
      if (stringValue != null) {
        _messagesController.add(stringValue);
      }
    }).toJS;
    socket.onerror = ((web.Event _) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('WebSocket failed to open'));
      }
    }).toJS;
    socket.onclose = ((web.CloseEvent event) {
      _socket = null;
      if (!completer.isCompleted) {
        completer.completeError(StateError('WebSocket closed during connect'));
      }
      _closeController.add(
        WebSocketCloseEvent(
          code: event.code,
          reason: event.reason,
          wasClean: event.wasClean,
        ),
      );
    }).toJS;

    await completer.future;
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeController.stream;

  @override
  void send(String message) {
    final socket = _socket;
    if (socket == null || socket.readyState != web.WebSocket.OPEN) {
      throw StateError('WebSocket is not connected');
    }
    socket.send(message.jsify()!);
  }

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  @override
  bool get isConnected => _socket?.readyState == web.WebSocket.OPEN;
}
