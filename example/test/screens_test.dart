import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint_example/main.dart';

void main() {
  testWidgets('every example screen builds from the home list', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    for (final screen in HomeScreen.screens) {
      await tester.tap(find.text(screen.title));
      // Not pumpAndSettle: the counter screen's spinner never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(screen.title), findsOneWidget, reason: screen.title);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
