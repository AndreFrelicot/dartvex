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

  @override
  Future<void> connect(String url) async {
    // Advancing the generation right after closing the previous socket is what
    // silences that socket: its late onclose fails the currentGeneration check
    // below, so it neither fails this connect nor emits a close event.
    _closeCurrent();
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
      final currentGeneration = generation == _connectGeneration;
      final currentSocket = identical(_socket, socket);
      if (currentSocket) {
        _socket = null;
      }
      if (currentGeneration && !completer.isCompleted) {
        completer.completeError(StateError('WebSocket closed during connect'));
      }
      if (!currentGeneration) {
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

  /// Closes the current socket.
  ///
  /// Deliberately does not advance the connect generation: a close() that
  /// races an in-flight connect must let that socket's onclose fail the
  /// pending connect future (so the caller is not left waiting for its
  /// connect timeout), and the close event of an open socket is still emitted
  /// so the sync layer can observe it (it ignores events it already handled).
  @override
  Future<void> close() async {
    _closeCurrent();
  }

  void _closeCurrent() {
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  @override
  bool get isConnected => _socket?.readyState == web.WebSocket.OPEN;
}
