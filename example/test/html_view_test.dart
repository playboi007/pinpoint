import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint_example/screens/html_view_screen.dart';

void main() {
  testWidgets('Add button opens palette and adds HTML components', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HtmlViewScreen()));

    expect(find.text('HtmlElementView'), findsOneWidget);
    expect(find.text('1 element'), findsOneWidget);
    expect(find.byKey(const Key('html_components_palette')), findsNothing);

    await tester.tap(find.byKey(const Key('add_html_element_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('html_components_palette')), findsOneWidget);
    expect(find.byKey(const Key('palette_item_heading')), findsOneWidget);
    expect(find.byKey(const Key('palette_item_button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('palette_item_heading')));
    await tester.pumpAndSettle();

    expect(find.text('2 elements'), findsOneWidget);
    expect(find.byKey(const Key('html_element_inspector')), findsOneWidget);
    expect(find.textContaining('Heading <h1>'), findsWidgets);
  });

  testWidgets('Dragging a component from palette drops it onto the canvas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HtmlViewScreen()));

    await tester.tap(find.byKey(const Key('add_html_element_button')));
    await tester.pumpAndSettle();

    final buttonTile = find.byKey(const Key('palette_item_button'));
    final tileCenter = tester.getCenter(buttonTile);
    const dropTarget = Offset(760, 380);

    final gesture = await tester.startGesture(tileCenter);
    await tester.pump();
    await gesture.moveTo(dropTarget);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('2 elements'), findsOneWidget);
    expect(find.byKey(const Key('html_element_inspector')), findsOneWidget);
    expect(find.textContaining('Button <button>'), findsWidgets);
  });

  testWidgets('Inspector edits text, duplicates, and previews HTML markup', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HtmlViewScreen()));

    await tester.tap(find.byKey(const Key('add_html_element_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('palette_item_heading')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('inspector_text_field')),
      'Custom Banner',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('view_html_markup_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('html_markup_panel')), findsOneWidget);
    expect(find.textContaining('Custom Banner'), findsWidgets);

    await tester.tap(find.byKey(const Key('duplicate_html_element_button')));
    await tester.pumpAndSettle();
    expect(find.text('3 elements'), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear_html_elements_button')));
    await tester.pumpAndSettle();
    expect(find.text('0 elements'), findsOneWidget);
    expect(
      find.text(
        'Click Add to choose HTML components or drag & drop them here',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Placed elements can be dragged in non-web preview', (
    tester,
  ) async {
    if (kIsWeb) return;

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: HtmlViewScreen()));

    final starter = find.byKey(const Key('stub_item_el_0'));
    final before = tester.getCenter(starter);

    await tester.drag(starter, const Offset(140, 90));
    await tester.pumpAndSettle();

    final after = tester.getCenter(starter);
    expect(after.dx, greaterThan(before.dx + 100));
    expect(after.dy, greaterThan(before.dy + 60));
  });
}
