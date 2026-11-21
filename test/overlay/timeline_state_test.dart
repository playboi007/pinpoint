import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/timeline_panel.dart';
import 'package:pinpoint/src/trace/cause_zone.dart';

import '../support/trace_host.dart';

/// PLAN-v3 Milestone 21, build step 7: the lens's events on the Timeline.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() {
    TimelinePanel.open.value = false;
    controller.dispose();
    CauseZone.debugReset();
  });

  testWidgets('state events sit under their cause with a short label, and '
      'the "only state" chip hides the rest', (tester) async {
    await tester.pumpWidget(
      traceApp(controller: controller, home: const Text('app')),
    );
    await tester.pump();
    CauseZone().run(() {});
    final tap = CauseZone.newCause(CauseKind.pointer)!;
    final press = recorder.add(
      TraceKind.pointer,
      data: const {'phase': 'down'},
      cause: tap,
    );
    final notify = recorder.add(
      TraceKind.stateNotify,
      widget: 'ProductModel',
      data: const {
        'owner': 'ProductModel',
        'tag': '#a1',
        'file': 'lib/product_model.dart',
        'line': 88,
        'method': 'ProductModel.fetchDialog',
      },
      cause: tap,
    );
    final setState = recorder.add(
      TraceKind.stateSetState,
      widget: 'Spinner',
      data: const {
        'file': 'lib/spinner.dart',
        'line': 12,
        'method': 'SpinnerState.toggle',
      },
      cause: tap,
    );
    final dropped = recorder.add(
      TraceKind.stateDropped,
      data: const {'n': 7},
      cause: tap,
    );

    await tester.tap(find.byKey(TimelinePanel.buttonKey));
    await tester.pump();

    expect(find.byKey(TimelinePanel.causeKey(tap.id)), findsOneWidget);
    for (final event in [notify, setState, dropped]) {
      expect(find.byKey(TimelinePanel.rowKey(event.seq)), findsOneWidget);
    }
    // The kind is not cut by an ellipsis: `state.setState` fits.
    expect(find.text('state.notify'), findsOneWidget);
    expect(find.text('state.setState'), findsOneWidget);
    expect(find.text('state.dropped'), findsOneWidget);
    // Owner, tag and method.
    final row = find.byKey(TimelinePanel.rowKey(notify.seq));
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('ProductModel #a1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('ProductModel.fetchDialog'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(TimelinePanel.rowKey(setState.seq)),
        matching: find.textContaining('Spinner setState'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(TimelinePanel.rowKey(dropped.seq)),
        matching: find.textContaining('7 setState stacks dropped'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(TimelinePanel.rowKey(press.seq)), findsOneWidget);

    await tester.tap(find.byKey(TimelinePanel.stateOnlyKey));
    await tester.pump();

    expect(find.byKey(TimelinePanel.rowKey(press.seq)), findsNothing);
    for (final event in [notify, setState, dropped]) {
      expect(find.byKey(TimelinePanel.rowKey(event.seq)), findsOneWidget);
    }

    await tester.tap(find.byKey(TimelinePanel.stateOnlyKey));
    await tester.pump();
    expect(find.byKey(TimelinePanel.rowKey(press.seq)), findsOneWidget);

    // The existing chip for `state` hides the lens's events too (kinds are
    // dotted names).
    await tester.tap(find.byKey(TimelinePanel.chipKey(TraceKind.state)));
    await tester.pump();
    expect(find.byKey(TimelinePanel.rowKey(notify.seq)), findsNothing);
    expect(find.byKey(TimelinePanel.rowKey(press.seq)), findsOneWidget);

    controller.stop();
    await tester.pump(const Duration(seconds: 2));
  });
}
