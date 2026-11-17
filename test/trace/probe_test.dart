import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/trace/trace_session.dart';

import '../support/trace_host.dart';

/// PLAN-v2 Milestone 13, build step 4: `PinPoint.probe`.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  testWidgets('a probe records its name and clipped values, and get_trace '
      'reads it', (tester) async {
    await tester.pumpWidget(
      traceApp(controller: controller, home: const Text('home')),
    );
    PinPoint.probe('existing.ensureLoaded', {
      'type': 'faq',
      'loaded': false,
      'cache': 'x' * 500,
      'items': List<int>.generate(40, (i) => i),
    });
    final probe = recorder.lastOf(TraceKind.probe)!;
    expect(probe.data['name'], 'existing.ensureLoaded');
    final values = probe.data['values']! as Map<String, Object?>;
    expect(values['type'], 'faq');
    expect(values['loaded'], false);
    expect((values['cache']! as String).length, 200);
    expect(values['items'], hasLength(20));

    final lines = await traceLines(tester, controller, {
      'kinds': ['probe'],
    });
    expect(
      lines.single,
      contains('probe  existing.ensureLoaded type=faq loaded=false'),
    );
  });

  testWidgets('acceptance: with Pinpoint off, PinPoint.probe records nothing '
      'and no source is installed', (tester) async {
    await tester.pumpWidget(
      traceApp(
        controller: controller,
        config: const PinPointConfig(enabled: false),
        home: const Text('home'),
      ),
    );
    expect(TraceSession.current, isNull);
    // Returns at its first line: nothing to record into, nothing thrown.
    PinPoint.probe('off', {'a': 1});
    expect(TraceSession.current, isNull);
    expect(debugOnRebuildDirtyWidget, isNull);
  });
}
