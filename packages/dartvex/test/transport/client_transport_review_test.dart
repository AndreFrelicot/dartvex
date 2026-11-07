// ConvexClient-level wiring for the 2026-11 transport review fixes (C10, F174,
// F176).
import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

import '../test_helpers/mock_web_socket_adapter.dart';

void main() {
  Future<void> waitUntil(bool Function() condition) async {
    final stopwatch = Stopwatch()..start();
    while (!condition()) {
      if (stopwatch.elapsed > const Duration(seconds: 2)) {
        fail('Timed out waiting for condition');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  test('onServerDisconnectError receives abnormal server close reasons',
      () async {
    final adapter = MockWebSocketAdapter();
    final reported = <String>[];
    final client = ConvexClient(
      'https://demo.convex.cloud',
      config: ConvexClientConfig(
        adapterFactory: (_) => adapter,
        reconnectBackoff: const <Duration>[Duration.zero],
      ),
      onServerDisconnectError: reported.add,
    );
    addTearDown(client.close);

    await waitUntil(() => adapter.isConnected);
    adapter.disconnect(code: 1011, reason: 'InternalServerError');
    await waitUntil(() => reported.isNotEmpty);

    expect(reported, <String>[
      'WebSocket closed with code 1011: InternalServerError',
    ]);
  });

  test('connectionStatus republishes connectionRetries changes', () async {
    final adapter = MockWebSocketAdapter();
    final client = ConvexClient(
      'https://demo.convex.cloud',
      config: ConvexClientConfig(
        adapterFactory: (_) => adapter,
        reconnectBackoff: const <Duration>[Duration(hours: 1)],
      ),
    );
    addTearDown(client.close);
    final statuses = <ConnectionStatus>[];
    final subscription = client.connectionStatus.listen(statuses.add);
    addTearDown(subscription.cancel);

    await waitUntil(() => adapter.isConnected);
    adapter.disconnect(code: 1006);
    await waitUntil(() => statuses.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // The increment happens after the disconnect was published; the stream
    // must still end on the incremented count.
    expect(statuses.last.connectionRetries, 1);
    expect(client.currentConnectionStatus.connectionRetries, 1);
  });
}
