import 'package:flutter_test/flutter_test.dart';

import 'package:dartvex_flutter_example/main.dart';

void main() {
  testWidgets('renders the package example app', (WidgetTester tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump();

    expect(find.text('dartvex_flutter'), findsOneWidget);
    expect(find.text('Realtime messages'), findsOneWidget);
    expect(find.text('Send a demo message'), findsOneWidget);
  });
}
