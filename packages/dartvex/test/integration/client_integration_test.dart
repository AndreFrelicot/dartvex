@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

void main() {
  final deploymentUrl = Platform.environment['CONVEX_DEPLOYMENT_URL'];
  final queryName = Platform.environment['CONVEX_TEST_QUERY'];
  final mutationName = Platform.environment['CONVEX_TEST_MUTATION'];
  final skipReason =
      deploymentUrl == null || queryName == null || mutationName == null
          ? 'Set CONVEX_DEPLOYMENT_URL, CONVEX_TEST_QUERY, and '
              'CONVEX_TEST_MUTATION to run real-deployment integration tests.'
          : null;

  group('live deployment integration', skip: skipReason, () {
    test('integration environment is configured', () {
      expect(deploymentUrl, isNotNull);
      expect(queryName, isNotNull);
      expect(mutationName, isNotNull);
    });

    test('configured mutation result is visible through configured query',
        () async {
      final client = ConvexClient(deploymentUrl!);
      addTearDown(client.dispose);

      await client.connectionState
          .firstWhere((state) => state == ConnectionState.connected)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw StateError(
              'ConvexClient did not connect within 10 seconds. '
              'Verify CONVEX_DEPLOYMENT_URL is reachable.',
            ),
          );

      final tag = 'dartvex-live-${DateTime.now().microsecondsSinceEpoch}';
      final result = await client.mutate(mutationName!, {
        'author': 'Dartvex Integration',
        'text': tag,
      }).timeout(const Duration(seconds: 30));

      expect(
        result,
        isNotNull,
        reason: 'The configured mutation should return a server value.',
      );

      final messages = await _waitForMessage(client, queryName!, tag);
      expect(
        messages.any((message) => _messageText(message) == tag),
        isTrue,
        reason: 'The configured query should include the inserted message.',
      );
    });
  });
}

Future<List<dynamic>> _waitForMessage(
  ConvexClient client,
  String queryName,
  String text,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  Object? lastResult;

  while (DateTime.now().isBefore(deadline)) {
    final result = await client.query(queryName).timeout(
          const Duration(seconds: 10),
        );
    lastResult = result;

    if (result is! List) {
      throw StateError(
        'Expected $queryName to return a List, got ${result.runtimeType}. '
        'Use a demo-compatible query such as messages:listPublic.',
      );
    }

    final messages = List<dynamic>.from(result);
    if (messages.any((message) => _messageText(message) == text)) {
      return messages;
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  throw StateError(
    'Timed out waiting for $queryName to include "$text". '
    'Last result: $lastResult',
  );
}

Object? _messageText(Object? message) {
  if (message is Map) {
    return message['text'];
  }
  return null;
}
