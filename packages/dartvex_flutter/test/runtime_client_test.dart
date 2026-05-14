import 'package:dartvex/dartvex.dart' as convex;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConvexClientRuntime', () {
    test('seeds currentConnectionState from wrapped client', () async {
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: const convex.ConvexClientConfig(connectImmediately: false),
      );
      final runtime = ConvexClientRuntime(client);

      expect(
        runtime.currentConnectionState,
        ConvexConnectionState.disconnected,
      );

      runtime.dispose();
      client.dispose();
    });
  });
}
