import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';
import 'package:pinpoint/src/overlay/rail.dart';
import 'package:pinpoint/src/overlay/theme_menu.dart';
import 'package:pinpoint/src/theme/palette_store.dart';
import 'package:pinpoint/src/theme/pinpoint_tokens.dart';

/// The theme menu, opened from the rail's palette item.
void main() {
  late MemoryPaletteStore store;
  late PinPointController controller;

  setUp(() {
    store = MemoryPaletteStore();
    controller = PinPointController(paletteStore: store);
  });
  tearDown(() => controller.dispose());

  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            PinPointWrapper(controller: controller, child: child),
        home: const Scaffold(body: Center(child: Text('app'))),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(ThemeMenu.buttonKey));
    await tester.pump();
    expect(find.byKey(ThemeMenu.menuKey), findsOneWidget);
  }

  final menu = find.byKey(ThemeMenu.menuKey);

  testWidgets('opens beside the palette item with a header, three rows and '
      'a footer', (tester) async {
    await pumpHost(tester);
    expect(menu, findsNothing);
    await open(tester);

    final rect = tester.getRect(menu);
    final item = tester.getRect(find.byKey(ThemeMenu.buttonKey));
    expect(rect.width, 220);
    expect(rect.right, lessThan(item.left), reason: 'left of the rail');
    expect(rect.top, item.top, reason: 'level with the item');
    expect(find.text('PINPOINT THEME'), findsOneWidget);
    for (final palette in PinPointPalette.values) {
      final row = find.byKey(ThemeMenu.rowKey(palette));
      expect(row, findsOneWidget);
      expect(tester.getSize(row).height, 30);
      expect(
        find.descendant(of: row, matching: find.text(palette.label)),
        findsOneWidget,
      );
    }
    expect(find.text('Saved for this project'), findsOneWidget);
  });

  testWidgets('a check marks the current palette only', (tester) async {
    await pumpHost(tester);
    await open(tester);
    Finder check(PinPointPalette p) => find.descendant(
      of: find.byKey(ThemeMenu.rowKey(p)),
      matching: find.byIcon(PinPointIcons.check),
    );
    expect(check(PinPointPalette.redline), findsOneWidget);
    expect(check(PinPointPalette.cobalt), findsNothing);
    expect(check(PinPointPalette.ember), findsNothing);
  });

  testWidgets('picking a row switches the palette, saves it and closes the '
      'menu', (tester) async {
    await pumpHost(tester);
    await open(tester);
    Color railPaper() =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: find.byKey(RailLayer.railKey),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color!;
    expect(railPaper(), PinPointTokens.redline.paper);

    await tester.tap(find.byKey(ThemeMenu.rowKey(PinPointPalette.cobalt)));
    await tester.pump();
    expect(controller.palette.value, PinPointPalette.cobalt);
    expect(store.read(), PinPointPalette.cobalt);
    expect(menu, findsNothing);
    expect(railPaper(), PinPointTokens.cobalt.paper);
  });

  testWidgets('Esc closes it', (tester) async {
    await pumpHost(tester);
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(menu, findsNothing);
    expect(controller.palette.value, PinPointPalette.redline);
  });

  testWidgets('a click outside closes it, and the palette item toggles it', (
    tester,
  ) async {
    await pumpHost(tester);
    await open(tester);
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(menu, findsNothing);

    await open(tester);
    await tester.tap(find.byKey(ThemeMenu.buttonKey));
    await tester.pump();
    expect(menu, findsNothing, reason: 'the item closes what it opened');
  });
}
