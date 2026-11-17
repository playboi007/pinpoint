import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/model/tape.dart';
import 'package:pinpoint/src/overlay/tape_range_picker.dart';
import 'package:pinpoint/src/tape/tape_recorder.dart';
import 'package:pinpoint/src/theme/pinpoint_theme.dart';

/// The range picker under "Attach what happened": which part of the run
/// the note's tape holds.
void main() {
  late int now;
  late TraceRecorder recorder;
  late TapeRecorder tapes;
  late CommentDraft draft;

  // The wall clock at recorder time 120 000 (two minutes in).
  final wallNow = DateTime(2026, 11, 14, 14, 2, 0);

  setUp(() {
    now = 0;
    recorder = TraceRecorder(clock: () => now);
    tapes = TapeRecorder(
      recorder,
      appStart: const TapeStart(t: 0, seq: 1, wallTime: 'start'),
    )..start();
    draft = CommentDraft();
    // Two minutes of use: a tap, a route change at 45 s, typing, a mark.
    now = 10000;
    recorder.add(TraceKind.pointer, data: {'phase': 'down', 'x': 1, 'y': 1});
    now = 45000;
    recorder.add(TraceKind.route, data: {'from': '/', 'to': '/form'});
    now = 70000;
    recorder.add(TraceKind.text, data: {'value': 'Ada', 'length': 3});
    now = 100000;
    recorder.add(TraceKind.mark, data: {'text': 'bug', 'by': 'user'});
    now = 120000;
  });

  tearDown(() => draft.dispose());

  const width = 320.0;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: pinPointThemeData(PinPointPalette.redline),
        home: Material(
          child: Center(
            child: SizedBox(
              width: width,
              child: TapeRangePicker(
                draft: draft,
                tapes: tapes,
                clock: () => wallNow,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String textOf(WidgetTester tester, Key key, {String join = ' '}) => [
    for (final t in tester.widgetList<Text>(
      find.descendant(of: find.byKey(key), matching: find.byType(Text)),
    ))
      t.data ?? '',
  ].join(join);

  /// The grip of the start handle, at the bottom of the track.
  Offset grip(WidgetTester tester, double fraction) {
    final track = tester.getTopLeft(find.byKey(TapeRangePicker.trackKey));
    return track + Offset(fraction * width, 57);
  }

  testWidgets('clear labels: from app start to now, with clock times, the '
      'length and what it holds', (tester) async {
    await pump(tester);
    expect(
      textOf(tester, TapeRangePicker.fromLabelKey),
      'FROM 14:00:00 app start',
    );
    expect(textOf(tester, TapeRangePicker.toLabelKey), 'TO now 14:02:00');
    expect(textOf(tester, TapeRangePicker.lengthKey, join: ''), '2:00');
    expect(find.text('FULL'), findsOneWidget);
    expect(find.text('1 tap · 1 text edit · 0 requests'), findsOneWidget);
    expect(
      find.text('Reloads the page and plays from app start'),
      findsOneWidget,
    );
  });

  testWidgets('a preset glides the start there: Last 30 s is a segment', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(TapeRangePicker.presetKey('30s')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(draft.tapeFrom, 90000);
    expect(draft.tapeTo, isNull);
    await tester.pumpAndSettle();
    expect(textOf(tester, TapeRangePicker.lengthKey, join: ''), '0:30');
    expect(
      textOf(tester, TapeRangePicker.fromLabelKey),
      'FROM 14:01:30 0:30 ago',
    );
    expect(find.text('SEGMENT'), findsOneWidget);
    expect(find.text('0 taps · 0 text edits · 0 requests'), findsOneWidget);
  });

  testWidgets('From mark starts at the last mark', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(TapeRangePicker.presetKey('mark')));
    await tester.pumpAndSettle();
    expect(draft.tapeFrom, 100000);
  });

  testWidgets('dragging the start handle moves the start; near a route '
      'change it snaps to it', (tester) async {
    await pump(tester);
    // 45 s is at 0.375 of the track; let go 4 px short of it.
    final gesture = await tester.startGesture(grip(tester, 0));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveTo(grip(tester, 0.375) - const Offset(4, 0));
    await tester.pump();
    expect(draft.tapeFrom, 45000);
    await gesture.moveTo(grip(tester, 0.6));
    await tester.pump();
    expect(draft.tapeFrom, closeTo(72000, 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(draft.tapeTo, isNull);
  });

  testWidgets('dragging the end handle back sets an end; the right edge is '
      'now again', (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(
      grip(tester, 1) - const Offset(1, 0),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveTo(grip(tester, 0.5));
    await tester.pump();
    expect(draft.tapeTo, closeTo(60000, 400));
    await gesture.moveTo(grip(tester, 1) + const Offset(20, 0));
    await tester.pump();
    expect(draft.tapeTo, isNull);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the handles keep half a second apart', (tester) async {
    await pump(tester);
    draft.setTapeRange(50000, 60000);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(grip(tester, 50000 / 120000));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(grip(tester, 0.9));
    await tester.pump();
    expect(draft.tapeFrom, 60000 - TapeRangePicker.minRange);
    await gesture.up();
    await tester.pumpAndSettle();
  });

  test('length and clock texts', () {
    expect(TapeRangePicker.length(0), '0:00');
    expect(TapeRangePicker.length(65000), '1:05');
    expect(TapeRangePicker.length(3723000), '1:02:03');
    expect(
      TapeRangePicker.clockTime(DateTime(2026, 1, 1, 9, 5, 7)),
      '09:05:07',
    );
  });
}
