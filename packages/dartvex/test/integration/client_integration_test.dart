import 'dart:io';

import 'package:test/test.dart';

void main() {
  final deploymentUrl = Platform.environment['CONVEX_DEPLOYMENT_URL'];
  final queryName = Platform.environment['CONVEX_TEST_QUERY'];
  final mutationName = Platform.environment['CONVEX_TEST_MUTATION'];

  test(
    'integration environment is configured',
    () {
      expect(deploymentUrl, isNotNull);
      expect(queryName, isNotNull);
      expect(mutationName, isNotNull);
    },
    skip: deploymentUrl == null || queryName == null || mutationName == null
        ? 'Set CONVEX_DEPLOYMENT_URL, CONVEX_TEST_QUERY, and '
            'CONVEX_TEST_MUTATION to run real-deployment integration tests.'
        : false,
  );
}
