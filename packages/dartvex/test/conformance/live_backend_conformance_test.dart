@Tags(['conformance', 'integration'])
library;

import 'dart:io';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

/// Live counterpart to `protocol_conformance_test.dart`: exercises the same
/// connect/subscribe/transition flow against a real Convex deployment.
///
/// Skipped unless `CONVEX_DEPLOYMENT_URL` and `CONVEX_TEST_QUERY` are set, so it
/// never fails CI when no backend is available. To run it locally, deploy the
/// demo backend (`example/convex-backend`, e.g. `npx convex dev`) and point the
/// env vars at it:
///
/// ```sh
/// CONVEX_DEPLOYMENT_URL=https://your-deployment.convex.cloud \
/// CONVEX_TEST_QUERY=messages:listPublic \
/// dart test test/conformance/live_backend_conformance_test.dart
/// ```
void main() {
  final deploymentUrl = Platform.environment['CONVEX_DEPLOYMENT_URL'];
  final queryName = Platform.environment['CONVEX_TEST_QUERY'];

  final skipReason = deploymentUrl == null || queryName == null
      ? 'Set CONVEX_DEPLOYMENT_URL and CONVEX_TEST_QUERY to run live protocol '
          'conformance against a real deployment (e.g. example/convex-backend '
          'via `npx convex dev`).'
      : null;

  group('protocol conformance (live backend)', () {
    test('connects, subscribes, and reports a synced ConnectionStatus',
        () async {
      final client = ConvexClient(deploymentUrl!);
      addTearDown(client.dispose);

      final subscription = client.subscribe(queryName!);
      final result = await subscription.stream
          .firstWhere(
            (event) => event is QuerySuccess || event is QueryError,
          )
          .timeout(const Duration(seconds: 30));

      expect(
        result,
        isA<QuerySuccess>(),
        reason: 'Expected the query to resolve against the live backend; '
            'verify CONVEX_DEPLOYMENT_URL is reachable and CONVEX_TEST_QUERY '
            'names a real query.',
      );

      final status = client.currentConnectionStatus;
      expect(status.isWebSocketConnected, isTrue);
      expect(status.hasEverConnected, isTrue);

      subscription.cancel();
    });
  }, skip: skipReason);
}
