import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint_example/main.dart';
import 'package:pinpoint_example/screens/environment_probe_screen.dart';

/// Milestone 9: the what-if switches, read through the example's probe.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  String probe(WidgetTester tester, String name) =>
      tester.widget<Text>(find.byKey(EnvironmentProbeScreen.line(name))).data!;

  Future<void> openProbe(WidgetTester tester) async {
    await tester.pumpWidget(ExampleApp(controller: controller));
    await tester.tap(find.text('What-if probe'));
    await tester.pumpAndSettle();
  }

  testWidgets("acceptance: dark mode uses the example's own darkTheme", (
    tester,
  ) async {
    await openProbe(tester);
    expect(probe(tester, 'brightness'), 'brightness: light');

    controller.environment.update(
      (e) => e.copyWith(brightness: () => Brightness.dark),
    );
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final probeContext = tester.element(find.byType(EnvironmentProbeScreen));
    expect(probe(tester, 'brightness'), 'brightness: dark');
    expect(Theme.of(probeContext).colorScheme, app.darkTheme!.colorScheme);
  });

  testWidgets('the probe reads 360 from MediaQuery and LayoutBuilder', (
    tester,
  ) async {
    await openProbe(tester);
    controller.environment.setViewport(const Size(360, 800));
    await tester.pumpAndSettle();
    expect(probe(tester, 'size'), 'size: 360 x 800');
    expect(probe(tester, 'constraints'), startsWith('constraints: 360 x'));
  });
}
