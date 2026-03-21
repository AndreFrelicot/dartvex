import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartvex/dartvex.dart';

Future<void> main() async {
  final deploymentUrl = Platform.environment['CONVEX_DEPLOYMENT_URL'];
  final queryName = Platform.environment['CONVEX_QUERY_NAME'];
  final mutationName = Platform.environment['CONVEX_MUTATION_NAME'];
  final queryArgs = _parseArgs(
    Platform.environment['CONVEX_QUERY_ARGS'],
    'CONVEX_QUERY_ARGS',
  );
  final mutationArgs = _parseArgs(
    Platform.environment['CONVEX_MUTATION_ARGS'],
    'CONVEX_MUTATION_ARGS',
  );

  if (deploymentUrl == null || queryName == null) {
    stderr.writeln(
      'Set CONVEX_DEPLOYMENT_URL and CONVEX_QUERY_NAME to run the example.',
    );
    exitCode = 64;
    return;
  }

  final client = ConvexClient(deploymentUrl);
  final subscription = client.subscribe(queryName, queryArgs);
  final subscriptionListener = subscription.stream.listen((result) {
    switch (result) {
      case QuerySuccess(:final value):
        stdout.writeln('subscription update: $value');
      case QueryError(:final message):
        stderr.writeln('subscription error: $message');
    }
  });

  try {
    final queryResult = await client.query(queryName, queryArgs);
    stdout.writeln('query result: $queryResult');

    if (mutationName != null) {
      final mutationResult = await client.mutate(mutationName, mutationArgs);
      stdout.writeln('mutation result: $mutationResult');
    }

    await Future<void>.delayed(const Duration(seconds: 10));
  } finally {
    await subscriptionListener.cancel();
    subscription.cancel();
    client.dispose();
  }
}

Map<String, dynamic> _parseArgs(String? raw, String envName) {
  if (raw == null || raw.trim().isEmpty) {
    return const <String, dynamic>{};
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('$envName must decode to a JSON object');
  }
  return decoded;
}
