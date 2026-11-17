import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/detect/detector.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';

/// PLAN-v2 Milestone 14, watch out for: stack traces of app errors get
/// zone frames. The overflow and error detectors of Milestone 10 must
/// still find the render object and the widget when the app runs inside
/// the cause zone. `flutter test` sets the binding up first, so the zone
/// is started by hand around the test's own zone, and the error comes from
/// a cause entered as a tap would be.
void main() {
  late PinPointController controller;
  final screen = GlobalKey<_ScreenState>();

  setUp(() => controller = PinPointController());
  tearDown(() {
    controller.dispose();
    CauseZone.debugReset();
  });

  Future<List<Finding>> showInCause(WidgetTester tester, Widget bad) async {
    final zone = CauseZone();
    await zone.run(() async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              PinPointWrapper(controller: controller, child: child),
          home: _Screen(key: screen, bad: bad),
        ),
      );
      CauseZone.enter(CauseKind.pointer, () => screen.currentState!.show());
      await tester.pump();
      expect(tester.takeException(), isNotNull);
      await tester.pump(Duration.zero);
    });
    return controller.findings.findings;
  }

  testWidgets('an overflow inside a cause still names its Row', (tester) async {
    final findings = await showInCause(
      tester,
      const SizedBox(
        width: 328,
        child: Row(
          children: [
            SizedBox(width: 200, height: 20),
            SizedBox(width: 200, height: 20),
          ],
        ),
      ),
    );
    final finding = findings.single;
    expect(finding.kind, 'overflow');
    expect(finding.element?.widget, isA<Row>());
    expect(finding.data['captured'], isTrue);
  });

  testWidgets('a build error inside a cause still names its widget, and its '
      'stack starts in app code, not in zone frames', (tester) async {
    final findings = await showInCause(tester, const _Broken());
    final finding = findings.single;
    expect(finding.kind, 'exception');
    expect(finding.element?.widget, isA<_Broken>());
    final stack = (finding.data['stack']! as List<Object?>).join('\n');
    expect(stack, contains('_Broken.build'));
  });
}

class _Screen extends StatefulWidget {
  const _Screen({super.key, required this.bad});

  final Widget bad;

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  bool _shown = false;

  void show() => setState(() => _shown = true);

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: _shown ? widget.bad : const SizedBox()));
}

class _Broken extends StatelessWidget {
  const _Broken();

  @override
  Widget build(BuildContext context) => throw StateError('planted in a cause');
}
