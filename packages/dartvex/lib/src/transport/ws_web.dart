import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'ws_interface.dart';

/// Creates the web platform [WebSocketAdapter]. The [clientId] is accepted for
/// signature parity with the native adapter but is unused by the web
/// implementation.
WebSocketAdapter createWebSocketAdapter(String clientId) {
  return WebPlatformWebSocketAdapter();
}

/// Browser [WebSocketAdapter] backed by the native `web.WebSocket`, bridging
/// the Convex sync transport to JS interop streams for messages and closes.
class WebPlatformWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast();

  web.WebSocket? _socket;
  int _connectGeneration = 0;
  int? _suppressedCloseGeneration;

  @override
  Future<void> connect(String url) async {
    _closeCurrent(suppressCloseEvent: true);
    final generation = ++_connectGeneration;
    final socket = web.WebSocket(url);
    final completer = Completer<void>();
    _socket = socket;

    bool isCurrentSocket() =>
        generation == _connectGeneration && identical(_socket, socket);

    socket.onopen = ((web.Event _) {
      if (!isCurrentSocket()) {
        socket.close();
        return;
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      if (!isCurrentSocket()) {
        return;
      }
      final data = event.data;
      final stringValue = (data as JSString?)?.toDart;
      if (stringValue != null && !_messagesController.isClosed) {
        _messagesController.add(stringValue);
      }
    }).toJS;
    socket.onerror = ((web.Event _) {
      if (!isCurrentSocket()) {
        return;
      }
      if (!completer.isCompleted) {
        completer.completeError(StateError('WebSocket failed to open'));
      }
    }).toJS;
    socket.onclose = ((web.CloseEvent event) {
      final suppressed = _suppressedCloseGeneration == generation;
      if (suppressed) {
        _suppressedCloseGeneration = null;
      }
      final currentGeneration = generation == _connectGeneration;
      final currentSocket = identical(_socket, socket);
      if (currentSocket) {
        _socket = null;
      }
      if (!suppressed && currentGeneration && !completer.isCompleted) {
        completer.completeError(StateError('WebSocket closed during connect'));
      }
      if (suppressed || !currentGeneration) {
        return;
      }
      if (!_closeController.isClosed) {
        _closeController.add(
          WebSocketCloseEvent(
            code: event.code,
            reason: event.reason,
            wasClean: event.wasClean,
          ),
        );
      }
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
    _closeCurrent(suppressCloseEvent: false);
  }

  void _closeCurrent({required bool suppressCloseEvent}) {
    final socket = _socket;
    _socket = null;
    if (socket != null && suppressCloseEvent) {
      _suppressedCloseGeneration = _connectGeneration;
    }
    socket?.close();
  }

  @override
  bool get isConnected => _socket?.readyState == web.WebSocket.OPEN;
}
