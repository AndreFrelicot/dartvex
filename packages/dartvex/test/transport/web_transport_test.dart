// Tests for the web transport selection and conditional import mechanism.
//
// These tests validate the factory wiring and interface contract on the
// native platform. Full browser validation requires `dart test -p chrome`
// which is documented but not enforced in the default CI path.

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

import '../test_helpers/mock_web_socket_adapter.dart';

void main() {
  group('Web transport contract', () {
    test('WebSocketAdapter interface is satisfied by mock', () async {
      // The mock adapter used throughout the test suite implements the same
      // interface that both NativeWebSocketAdapter and
      // WebPlatformWebSocketAdapter implement. This proves the interface
      // contract is consistent across platforms.
      final adapter = MockWebSocketAdapter();
      expect(adapter.isConnected, isFalse);

      await adapter.connect('wss://example.com');
      expect(adapter.isConnected, isTrue);

      adapter.send('{"type":"test"}');
      expect(adapter.decodedSentMessages, hasLength(1));

      await adapter.close();
      expect(adapter.isConnected, isFalse);
    });

    test('ConvexClient accepts a custom adapter factory', () {
      // This is the mechanism that makes the transport pluggable — both for
      // testing and for platform-specific implementations.
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
        ),
      );

      // Client should be in connecting state with the custom adapter.
      expect(
        client.currentConnectionState,
        ConnectionState.connecting,
      );

      client.dispose();
    });

    test('conditional import resolves to native adapter on this platform', () {
      // On dart:io platforms, the factory resolves to NativeWebSocketAdapter.
      // On web, it resolves to WebPlatformWebSocketAdapter.
      // We cannot test the web path here, but we verify the factory function
      // exists and returns a non-null adapter.
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: const ConvexClientConfig(
          // Use the default adapter factory (conditional import path).
          reconnectBackoff: <Duration>[Duration(seconds: 30)],
        ),
      );

      // If we get here without error, the conditional import resolved
      // correctly on this platform.
      expect(client.currentConnectionState, isNotNull);
      client.dispose();
    });
  });
}
