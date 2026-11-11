import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/theme/controls.dart';
import 'package:pinpoint/src/theme/marks.dart';
import 'package:pinpoint/src/theme/pinpoint_theme.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

Widget _host(
  Widget child, {
  PinPointPalette palette = PinPointPalette.redline,
}) => MaterialApp(
  theme: pinPointThemeData(palette),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  const tokens = PinPointTokens.redline;

  group('StartEllipsisText', () {
    const path =
        '/lib/src/features/dashboard/presentation/dashboard_panels.dart:652';

    Future<String> shown(WidgetTester tester, double width, String text) async {
      await tester.pumpWidget(
        _host(SizedBox(width: width, child: StartEllipsisText(text))),
      );
      return tester
          .widget<Text>(
            find.descendant(
              of: find.byType(StartEllipsisText),
              matching: find.byType(Text),
            ),
          )
          .data!;
    }

    testWidgets('keeps the end and starts with an ellipsis', (tester) async {
      final text = await shown(tester, 400, path);
      expect(text, startsWith('…'));
      expect(text, endsWith('dashboard_panels.dart:652'));
      // Cut at a slash, so no folder name is left half.
      expect(text, startsWith('…/'));
      expect(text.length, lessThan(path.length));
    });

    testWidgets('leaves a text that fits alone', (tester) async {
      const short = '…/widgets/save_bar.dart:28';
      expect(await shown(tester, 400, short), short);
    });

    testWidgets('cuts inside the name when it is longer than the box', (
      tester,
    ) async {
      final text = await shown(tester, 120, 'a_very_long_file_name.dart:12');
      expect(text, startsWith('…'));
      expect(text, endsWith('.dart:12'));
    });
  });

  group('DraftButton', () {
    testWidgets('a disabled primary has no fill and a dashed border', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const DraftButton.primary(label: 'Send', onPressed: null)),
      );
      expect(find.byType(DashedBox), findsOneWidget);
      expect(_decorated(tester, tokens.accent), isEmpty);
      expect(tester.widget<Text>(find.text('Send')).style?.color, tokens.faint);

      await tester.pumpWidget(
        _host(DraftButton.primary(label: 'Send', onPressed: () {})),
      );
      expect(find.byType(DashedBox), findsNothing);
      expect(_decorated(tester, tokens.accent), hasLength(1));
      expect(
        tester.widget<Text>(find.text('Send')).style?.color,
        tokens.onAccent,
      );
    });

    testWidgets('outline is never dashed, and a tap calls onPressed', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          DraftButton.outline(label: 'Save draft', onPressed: () => taps++),
        ),
      );
      expect(find.byType(DashedBox), findsNothing);
      await tester.tap(find.text('Save draft'));
      expect(taps, 1);
    });

    testWidgets('a disabled button ignores taps', (tester) async {
      await tester.pumpWidget(
        _host(const DraftButton.link(label: 'Cancel', onPressed: null)),
      );
      await tester.tap(find.text('Cancel'), warnIfMissed: false);
      expect(tester.takeException(), isNull);
    });
  });

  group('DraftChip', () {
    testWidgets('override shows a close that calls onClear', (tester) async {
      var cleared = 0;
      var taps = 0;
      await tester.pumpWidget(
        _host(
          DraftChip(
            label: 'RTL',
            look: ChipLook.override,
            onTap: () => taps++,
            onClear: () => cleared++,
          ),
        ),
      );
      expect(find.byIcon(PinPointIcons.close), findsOneWidget);
      await tester.tap(find.byIcon(PinPointIcons.close));
      expect(cleared, 1);
      expect(taps, 0);
    });

    testWidgets('selected shows a check; disabled is dashed', (tester) async {
      await tester.pumpWidget(
        _host(
          const DraftChip(
            label: 'Improve',
            icon: PinPointIcons.improve,
            look: ChipLook.selected,
            mono: false,
          ),
        ),
      );
      expect(find.byIcon(PinPointIcons.check), findsOneWidget);
      expect(find.byIcon(PinPointIcons.improve), findsNothing);

      await tester.pumpWidget(
        _host(const DraftChip(label: 'fuchsia', look: ChipLook.disabled)),
      );
      expect(find.byType(DashedBox), findsOneWidget);
    });
  });

  testWidgets('DraftSegmented calls onChanged with the tapped value', (
    tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      _host(
        DraftSegmented<int>(
          items: const [(1, '1'), (4, '4'), (8, '8')],
          value: 4,
          onChanged: (value) => picked = value,
        ),
      ),
    );
    await tester.tap(find.text('8'));
    expect(picked, 8);
  });

  testWidgets('DraftCheckbox toggles', (tester) async {
    bool? value;
    await tester.pumpWidget(
      _host(
        DraftCheckbox(
          value: false,
          label: 'Include screenshot',
          onChanged: (v) => value = v,
        ),
      ),
    );
    expect(find.byIcon(PinPointIcons.check), findsNothing);
    await tester.tap(find.text('Include screenshot'));
    expect(value, isTrue);
  });

  testWidgets('DraftStepper buttons call back; disabled does not', (
    tester,
  ) async {
    var minus = 0;
    var plus = 0;
    await tester.pumpWidget(
      _host(
        DraftStepper(
          value: const Text('44'),
          onMinus: () => minus++,
          onPlus: () => plus++,
        ),
      ),
    );
    await tester.tap(find.text('−'));
    await tester.tap(find.text('+'));
    expect((minus, plus), (1, 1));

    await tester.pumpWidget(
      _host(
        DraftStepper(
          value: const Text('∞'),
          state: FieldState.disabled,
          onMinus: () => minus++,
          onPlus: () => plus++,
        ),
      ),
    );
    expect(find.byType(DashedBox), findsOneWidget);
    await tester.tap(find.text('+'));
    expect((minus, plus), (1, 1));
  });

  group('DraftFieldFrame', () {
    testWidgets('has a distinct look for each state', (tester) async {
      Future<BoxDecoration?> decorationOf(FieldState state) async {
        await tester.pumpWidget(
          _host(
            SizedBox(
              width: 100,
              child: DraftFieldFrame(state: state, child: const Text('x')),
            ),
          ),
        );
        final container = find.descendant(
          of: find.byType(DraftFieldFrame),
          matching: find.byType(Container),
        );
        return container.evaluate().isEmpty
            ? null
            : tester.widget<Container>(container.first).decoration
                  as BoxDecoration?;
      }

      final rest = (await decorationOf(FieldState.rest))!;
      expect(rest.color, tokens.input);
      expect((rest.border! as Border).top.color, tokens.field);

      final focus = (await decorationOf(FieldState.focus))!;
      expect((focus.border! as Border).top.color, tokens.ink);
      expect(focus.boxShadow!.single.color, tokens.accentBg);

      final tweaked = (await decorationOf(FieldState.tweaked))!;
      expect(tweaked.color, tokens.editBg);
      expect((tweaked.border! as Border).top.width, 1.5);

      final invalid = (await decorationOf(FieldState.invalid))!;
      expect((invalid.border! as Border).top.color, tokens.err);

      expect(await decorationOf(FieldState.disabled), isNull);
      expect(find.byType(DashedBox), findsOneWidget);
    });
  });

  testWidgets('badges render their text', (tester) async {
    await tester.pumpWidget(
      _host(
        const Wrap(
          children: [
            CountBadge(12),
            SeverityBadge(PinPointSeverityLook.error),
            SeverityBadge(PinPointSeverityLook.warn),
            SeverityBadge(PinPointSeverityLook.info),
            SystemBadge.bridgeOffline(detail: 'No bridge at 127.0.0.1:4747'),
            SystemBadge.frozen(),
          ],
        ),
      ),
    );
    for (final text in [
      '12',
      'ERROR',
      'WARN',
      'INFO',
      'BRIDGE OFFLINE',
      'FROZEN',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
  });

  testWidgets('DraftSpinner turns while mounted and stops when removed', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const DraftSpinner()));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(_host(const SizedBox()));
    // Without the spinner the tree settles at once.
    await tester.pumpAndSettle();
  });

  group('marks', () {
    test('dashPath splits a line into dashes', () {
      final line = Path()..lineTo(20, 0);
      final dashed = dashPath(line, const [4, 3]);
      final lengths = dashed.computeMetrics().map((m) => m.length).toList();
      // 0-4, 7-11, 14-18; the last 2 px of the line is a gap of 3.
      expect(lengths, [4, 4, 4]);
    });

    test('dashPath restarts at each contour of a closed rect', () {
      final rect = Path()..addRect(const Rect.fromLTWH(0, 0, 10, 10));
      final dashed = dashPath(rect, const [4, 3]);
      final total = dashed.computeMetrics().fold<double>(
        0,
        (s, m) => s + m.length,
      );
      // 40 px of edge: dashes of 4 at 0, 7, ... 35 (one cut short at 39).
      expect(total, closeTo(24, 0.01));
    });

    test('dashPath leaves the path alone for a pattern that adds to zero', () {
      final line = Path()..lineTo(5, 0);
      expect(dashPath(line, const []), same(line));
      expect(dashPath(line, const [0, 0]), same(line));
    });

    test('the rect helpers paint without error', () {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      const rect = Rect.fromLTWH(10, 10, 100, 40);
      paintHover(canvas, rect, tokens);
      paintSelected(canvas, rect, tokens);
      paintTweaked(canvas, rect, tokens);
      paintAgentFlash(canvas, rect, tokens, 0.5);
      strokeHalo(
        canvas,
        Path()..lineTo(50, 0),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = tokens.ink,
        tokens,
        dash: const [3, 3],
      );
      recorder.endRecording().dispose();
    });
  });
}

/// The `DecoratedBox`es under the first `Scaffold` body filled with [color].
List<DecoratedBox> _decorated(WidgetTester tester, Color color) => [
  for (final box in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox)))
    if (box.decoration is BoxDecoration &&
        (box.decoration as BoxDecoration).color == color)
      box,
];
