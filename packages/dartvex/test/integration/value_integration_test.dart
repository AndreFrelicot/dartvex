// Integration tests for special Convex value handling over the live protocol.
//
// These tests require:
//   CONVEX_DEPLOYMENT_URL — a Convex deployment with the demo backend deployed
//
// The demo backend must include `convex/testing.ts` with the
// `specialValuesSnapshot` query and `echoValues` action. Deploy with:
//   cd demo/convex-backend && npx convex deploy
//
// Run:
//   CONVEX_DEPLOYMENT_URL=https://your.convex.cloud \
//     dart test test/integration/value_integration_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

void main() {
  final deploymentUrl = Platform.environment['CONVEX_DEPLOYMENT_URL'];
  final skip = deploymentUrl == null
      ? 'Set CONVEX_DEPLOYMENT_URL to run value integration tests. '
          'The demo backend must include convex/testing.ts (deploy first).'
      : null;

  group('Special Convex value round-trips', skip: skip, () {
    late ConvexClient client;

    setUpAll(() async {
      client = ConvexClient(deploymentUrl!);
      // Wait for the client to connect before running tests.
      await client.connectionState
          .firstWhere((state) => state == ConnectionState.connected)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw StateError(
              'ConvexClient did not connect within 10 seconds. '
              'Verify CONVEX_DEPLOYMENT_URL is reachable.',
            ),
          );
    });

    tearDownAll(() {
      client.dispose();
    });

    test('query returns Int64 values as BigInt', () async {
      final result = await client.query('testing:specialValuesSnapshot');
      final map = result as Map<String, dynamic>;

      expect(map['largePositive'], BigInt.parse('9007199254740993'));
      expect(map['largeNegative'], BigInt.parse('-9007199254740993'));
      expect(map['zero'], BigInt.zero);
    });

    test('query returns bytes as Uint8List', () async {
      final result = await client.query('testing:specialValuesSnapshot');
      final map = result as Map<String, dynamic>;

      final bytes = map['sampleBytes'] as Uint8List;
      expect(bytes, orderedEquals(<int>[0xDE, 0xAD, 0xBE, 0xEF]));
    });

    test('action round-trips BigInt through arguments and return', () async {
      final input = BigInt.parse('9007199254740993');
      final inputBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

      final result = await client.action('testing:echoValues', {
        'intValue': input,
        'bytesValue': inputBytes,
      });
      final map = result as Map<String, dynamic>;

      expect(map['intValue'], input);
      expect(map['intPlusOne'], input + BigInt.one);
      expect(map['bytesLength'], 5);
    });

    test('action round-trips bytes through arguments and return', () async {
      final inputBytes = Uint8List.fromList(<int>[0xFF, 0x00, 0x42]);

      final result = await client.action('testing:echoValues', {
        'intValue': BigInt.zero,
        'bytesValue': inputBytes,
      });
      final map = result as Map<String, dynamic>;

      final echoed = map['bytesValue'] as Uint8List;
      expect(echoed, orderedEquals(inputBytes));
    });
  });
}
