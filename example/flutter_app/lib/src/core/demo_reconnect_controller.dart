// ignore_for_file: implementation_imports

import 'package:dartvex/src/transport/ws_factory.dart';
import 'package:dartvex/src/transport/ws_interface.dart';

class DemoReconnectController {
  _ReconnectableWebSocketAdapter? _activeAdapter;

  WebSocketAdapter createAdapter(String clientId) {
    final adapter = _ReconnectableWebSocketAdapter(
      createDefaultWebSocketAdapter(clientId),
    );
    _activeAdapter = adapter;
    return adapter;
  }

  bool get canForceReconnect => _activeAdapter?.isConnected ?? false;

  Future<void> forceReconnect() async {
    final adapter = _activeAdapter;
    if (adapter == null || !adapter.isConnected) {
      throw StateError('Connection is not established yet.');
    }
    await adapter.forceReconnect();
  }
}

class _ReconnectableWebSocketAdapter implements WebSocketAdapter {
  _ReconnectableWebSocketAdapter(this._delegate);

  final WebSocketAdapter _delegate;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<void> connect(String url) => _delegate.connect(url);

  Future<void> forceReconnect() => _delegate.close();

  @override
  bool get isConnected => _delegate.isConnected;

  @override
  Stream<void> get closeEvents => _delegate.closeEvents;

  @override
  Stream<String> get messages => _delegate.messages;

  @override
  void send(String message) => _delegate.send(message);
}
