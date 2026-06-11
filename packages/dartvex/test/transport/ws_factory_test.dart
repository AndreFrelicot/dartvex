import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

class _FakeAdapter implements WebSocketAdapter {
  @override
  Future<void> connect(String url) async {}

  @override
  void send(String message) {}

  @override
  Stream<String> get messages => const Stream<String>.empty();

  @override
  Stream<WebSocketCloseEvent> get closeEvents =>
      const Stream<WebSocketCloseEvent>.empty();

  @override
  Future<void> close() async {}

  @override
  bool get isConnected => false;
}

void main() {
  tearDown(() {
    defaultWebSocketAdapterOverride = null;
  });

  test('createDefaultWebSocketAdapter delegates to the override when set', () {
    final created = <String>[];
    defaultWebSocketAdapterOverride = (String clientId) {
      created.add(clientId);
      return _FakeAdapter();
    };
    final adapter = createDefaultWebSocketAdapter('client-1');
    expect(adapter, isA<_FakeAdapter>());
    expect(created, ['client-1']);
  });

  test('createDefaultWebSocketAdapter falls back to the platform adapter', () {
    defaultWebSocketAdapterOverride = null;
    final adapter = createDefaultWebSocketAdapter('client-2');
    expect(adapter, isNot(isA<_FakeAdapter>()));
  });
}
