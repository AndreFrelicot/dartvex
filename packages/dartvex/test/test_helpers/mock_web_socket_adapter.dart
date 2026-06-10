import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/transport/ws_interface.dart';

class MockWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast();

  final List<String> sentMessages = <String>[];
  final List<String> connectedUrls = <String>[];
  bool _connected = false;

  /// When true, [close] throws without emitting a close event, simulating a
  /// socket that fails to close cleanly (e.g. on an inactivity timeout).
  bool throwOnClose = false;

  @override
  Future<void> connect(String url) async {
    connectedUrls.add(url);
    _connected = true;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Mock socket is disconnected');
    }
    sentMessages.add(message);
  }

  List<Map<String, dynamic>> get decodedSentMessages {
    return sentMessages
        .map((message) => jsonDecode(message) as Map<String, dynamic>)
        .toList(growable: false);
  }

  void pushServerMessage(Map<String, dynamic> message) {
    _messagesController.add(jsonEncode(message));
  }

  /// Emits a close event without touching the connected state, simulating a
  /// superseded socket whose delayed teardown completes only after a newer
  /// socket has already connected (e.g. a native close that timed out on a
  /// dead network and was force-destroyed by the platform later).
  void emitStaleCloseEvent({int? code, String? reason}) {
    _closeController.add(WebSocketCloseEvent(code: code, reason: reason));
  }

  void disconnect({
    int? code,
    String? reason,
    bool? wasClean,
    String? errorMessage,
  }) {
    _connected = false;
    _closeController.add(
      WebSocketCloseEvent(
        code: code,
        reason: reason,
        wasClean: wasClean,
        errorMessage: errorMessage,
      ),
    );
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeController.stream;

  @override
  Future<void> close() async {
    if (throwOnClose) {
      throw StateError('Mock socket failed to close');
    }
    if (!_connected) {
      return;
    }
    disconnect();
  }

  @override
  bool get isConnected => _connected;
}
