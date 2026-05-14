import 'package:dartvex/dartvex.dart' as convex;
import 'package:dartvex_local/dartvex_local.dart';
import 'package:test/test.dart';

void main() {
  group('ConvexRemoteClientAdapter', () {
    test('seeds currentConnectionState from wrapped client', () async {
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: const convex.ConvexClientConfig(connectImmediately: false),
      );
      final adapter = ConvexRemoteClientAdapter(client);

      expect(
        adapter.currentConnectionState,
        LocalRemoteConnectionState.disconnected,
      );

      adapter.dispose();
      client.dispose();
    });
  });
}
