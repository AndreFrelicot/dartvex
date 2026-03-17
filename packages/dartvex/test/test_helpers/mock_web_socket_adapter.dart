import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/transport/ws_interface.dart';

class MockWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<void> _closeController =
      StreamController<void>.broadcast();

  final List<String> sentMessages = <String>[];
  final List<String> connectedUrls = <String>[];
  bool _connected = false;

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

  void disconnect() {
    _connected = false;
    _closeController.add(null);
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<void> get closeEvents => _closeController.stream;

  @override
  Future<void> close() async {
    if (!_connected) {
      return;
    }
    disconnect();
  }

  @override
  bool get isConnected => _connected;
}
