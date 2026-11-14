import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/overlay/tape_range_picker.dart';
import 'package:pinpoint/src/tape/tape_recorder.dart';
import 'package:pinpoint/src/theme/pinpoint_motion.dart';
import 'package:pinpoint/src/theme/pinpoint_theme.dart';

/// Pinpoint's motion values: one set of durations and curves, zero with
/// reduced motion, and free of the What-if slow motion.
void main() {
  test('the tiers keep their design values by default', () {
    const motion = PinPointMotion();
    expect(motion.snap, const Duration(milliseconds: 80));
    expect(motion.quick, const Duration(milliseconds: 150));
    expect(motion.moderate, const Duration(milliseconds: 250));
    expect(motion.expressive, const Duration(milliseconds: 420));
  });

  test('reduced motion: every duration is zero, but what tells something '
      'still moves', () {
    const motion = PinPointMotion(reduced: true);
    expect(motion.snap, Duration.zero);
    expect(motion.expressive, Duration.zero);
    expect(motion.scaled(const Duration(seconds: 1)), Duration.zero);
    expect(
      motion.informative(const Duration(milliseconds: 800)),
      const Duration(milliseconds: 800),
    );
  });

  test('slow motion x5: Pinpoint divides by it, so it keeps its speed', () {
    const motion = PinPointMotion(dilation: 5);
    expect(motion.quick, const Duration(milliseconds: 30));
    expect(
      motion.informative(const Duration(milliseconds: 800)),
      const Duration(milliseconds: 160),
    );
  });

  testWidgets('of reads MediaQuery.disableAnimations and timeDilation', (
    tester,
  ) async {
    late PinPointMotion seen;
    Widget probe({required bool reduce}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduce),
      child: Builder(
        builder: (context) {
          seen = PinPointMotion.of(context);
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(probe(reduce: true));
    expect(seen.reduced, isTrue);
    timeDilation = 2;
    try {
      await tester.pumpWidget(probe(reduce: false));
    } finally {
      // The binding checks it before tear-down runs.
      timeDilation = 1;
    }
    expect(seen, const PinPointMotion(dilation: 2));
  });

  testWidgets('with reduced motion, a range preset lands at once', (
    tester,
  ) async {
    var now = 0;
    final recorder = TraceRecorder(clock: () => now);
    final tapes = TapeRecorder(
      recorder,
      appStart: const TapeStart(t: 0, seq: 1, wallTime: 'start'),
    )..start();
    final draft = CommentDraft();
    addTearDown(draft.dispose);
    now = 120000;
    Future<void> pump({required bool reduce}) => tester.pumpWidget(
      MaterialApp(
        theme: pinPointThemeData(PinPointPalette.redline),
        // Inside the app: MaterialApp makes its own MediaQuery.
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: Material(
            child: SizedBox(
              width: 320,
              child: TapeRangePicker(draft: draft, tapes: tapes),
            ),
          ),
        ),
      ),
    );

    await pump(reduce: false);
    await tester.tap(find.byKey(TapeRangePicker.presetKey('30s')));
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();

    // A new picker: an AnimatedSwitcher child made before the switch keeps
    // its old duration for one exit (Flutter's behavior).
    await tester.pumpWidget(const SizedBox());
    await pump(reduce: true);
    await tester.tap(find.byKey(TapeRangePicker.presetKey('all')));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(draft.tapeFrom, 0);
  });
}
