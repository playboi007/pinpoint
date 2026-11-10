import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint_example/main.dart';

void main() {
  testWidgets('every example screen builds from the home list', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    for (final screen in HomeScreen.screens) {
      await tester.tap(find.text(screen.title));
      await tester.pumpAndSettle();
      expect(find.text(screen.title), findsOneWidget, reason: screen.title);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });
}
