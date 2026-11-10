import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';

/// Pumps until [controller] leaves `sending`, or ten rounds.
///
/// Send captures a screenshot by default. The engine makes the image
/// outside the test's fake clock, so `pump` alone never finishes it: each
/// round also gives it real time.
Future<void> finishSend(
  WidgetTester tester,
  PinPointController controller,
) async {
  for (var i = 0; i < 10 && controller.mode == PinPointMode.sending; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  await tester.pump();
}
