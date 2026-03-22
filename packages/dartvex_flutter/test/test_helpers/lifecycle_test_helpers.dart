import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simulates an app lifecycle state change in widget tests.
void simulateAppLifecycleState(
  WidgetTester tester,
  AppLifecycleState state,
) {
  tester.binding.handleAppLifecycleStateChanged(state);
}
