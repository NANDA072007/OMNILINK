import 'package:flutter_test/flutter_test.dart';

import 'package:omnilink/main.dart';

void main() {
  testWidgets('OMNILINK app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const OmnilinkApp());

    // Verify that the discovery screen is shown.
    expect(find.byType(OmnilinkApp), findsOneWidget);
  });
}
