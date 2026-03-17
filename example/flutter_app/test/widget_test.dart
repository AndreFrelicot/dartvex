// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:dartvex_flutter_demo/src/app.dart';

void main() {
  testWidgets('shows configuration guidance without deployment url', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ConvexFlutterDemoApp(deploymentUrlOverride: ''),
    );

    expect(find.textContaining('Set CONVEX_DEMO_URL'), findsWidgets);
    expect(find.text('Chats'), findsWidgets);
    expect(find.text('Tasks'), findsWidgets);
    expect(find.text('Public Realtime Feed'), findsOneWidget);
    expect(find.text('Disconnected'), findsWidgets);
  });
}
