import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/overlay/construction/construction_blueprint.dart';
import 'package:pinpoint/src/overlay/construction/construction_boxes.dart';

/// The blueprint of a widget, read once from the render tree.
void main() {
  const rootKey = Key('root');

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(alignment: Alignment.topLeft, child: child),
    ),
  );

  Rect rectOf(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

  List<ConstructionBox> read(WidgetTester tester, [Rect? widget]) =>
      ConstructionBlueprint.read(
        tester.renderObject(find.byKey(rootKey)),
        widget ?? rectOf(tester, rootKey),
      );

  ConstructionBox relative(WidgetTester tester, Key key) {
    final root = rectOf(tester, rootKey);
    final r = rectOf(tester, key);
    return ConstructionBox(
      r.left - root.left,
      r.top - root.top,
      r.width,
      r.height,
    );
  }

  testWidgets('the boxes are the descendants\' rects, relative to the widget', (
    tester,
  ) async {
    await pump(
      tester,
      Padding(
        padding: const EdgeInsets.all(30),
        child: Container(
          key: rootKey,
          width: 200,
          height: 60,
          padding: const EdgeInsets.all(10),
          child: const Row(
            children: [
              SizedBox(key: Key('a'), width: 40, height: 20),
              SizedBox(key: Key('b'), width: 60, height: 30),
              SizedBox(key: Key('c'), width: 30, height: 40),
            ],
          ),
        ),
      ),
    );
    final boxes = read(tester);
    for (final key in const [Key('a'), Key('b'), Key('c')]) {
      expect(
        boxes.any((b) {
          final r = relative(tester, key);
          return (b.left - r.left).abs() < 0.11 &&
              (b.top - r.top).abs() < 0.11 &&
              (b.width - r.width).abs() < 0.11 &&
              (b.height - r.height).abs() < 0.11;
        }),
        isTrue,
        reason: '$key is in $boxes',
      );
    }
    // The row is a container around them: its own box is kept.
    expect(boxes.length, 4, reason: '$boxes');
    // In the widget's own space: nothing is outside it.
    for (final b in boxes) {
      expect(b.left, greaterThanOrEqualTo(0));
      expect(b.top, greaterThanOrEqualTo(0));
      expect(b.left + b.width, lessThanOrEqualTo(200.01));
      expect(b.top + b.height, lessThanOrEqualTo(60.01));
    }
    // The widget does not move with the page: same boxes anywhere.
    final first = boxes;
    await pump(
      tester,
      Padding(
        padding: const EdgeInsets.fromLTRB(5, 70, 0, 0),
        child: Container(
          key: rootKey,
          width: 200,
          height: 60,
          padding: const EdgeInsets.all(10),
          child: const Row(
            children: [
              SizedBox(key: Key('a'), width: 40, height: 20),
              SizedBox(key: Key('b'), width: 60, height: 30),
              SizedBox(key: Key('c'), width: 30, height: 40),
            ],
          ),
        ),
      ),
    );
    expect(read(tester), first);
  });

  testWidgets('boxes under 4 px are skipped, 4 px is kept', (tester) async {
    await pump(
      tester,
      const SizedBox(
        key: rootKey,
        width: 100,
        height: 40,
        child: Row(
          children: [
            SizedBox(width: 3, height: 30),
            SizedBox(width: 30, height: 3),
            SizedBox(width: 4, height: 4),
            SizedBox(width: 10, height: 10),
          ],
        ),
      ),
    );
    final boxes = read(tester);
    expect(boxes.where((b) => b.width < 4 || b.height < 4), isEmpty);
    expect(boxes.any((b) => b.width == 4 && b.height == 4), isTrue);
    expect(boxes.any((b) => b.width == 10 && b.height == 10), isTrue);
  });

  testWidgets('a box with the rect of its parent or of the widget is skipped', (
    tester,
  ) async {
    await pump(
      tester,
      const SizedBox(
        key: rootKey,
        width: 120,
        height: 40,
        child: Padding(
          padding: EdgeInsets.zero,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Colors.red),
            child: Center(child: SizedBox(width: 60, height: 20)),
          ),
        ),
      ),
    );
    final boxes = read(tester);
    // The wrappers all have the widget's rect. The centred box is the only
    // one: Center fills, so only the inner box differs.
    expect(boxes, [const ConstructionBox(30, 10, 60, 20)]);
  });

  testWidgets('a widget with no box inside has no boxes', (tester) async {
    await pump(tester, const Text('hello', key: rootKey));
    expect(read(tester), isEmpty);
  });

  testWidgets('a box that frames nearly everything is left out, and the '
      'count is capped, biggest first', (tester) async {
    await pump(
      tester,
      SizedBox(
        key: rootKey,
        width: 400,
        height: 400,
        child: Wrap(
          children: [
            for (var i = 0; i < 70; i++)
              SizedBox(width: 10.0 + (i % 3), height: 10),
          ],
        ),
      ),
    );
    final boxes = read(tester);
    expect(boxes, hasLength(ConstructionBoxes.maxBoxes));
    // The Wrap (it frames the whole widget) went, the parts stayed.
    expect(boxes.every((b) => b.width <= 12 && b.height == 10), isTrue);
    // The biggest leaves came first: no 10 px box when a 12 px one waited.
    final twelve = boxes.where((b) => b.width == 12).length;
    expect(twelve, greaterThan(0));
    // Paint order: reading order here.
    for (var i = 1; i < boxes.length; i++) {
      final a = boxes[i - 1];
      final b = boxes[i];
      expect(b.top > a.top || b.left > a.left, isTrue);
    }
  });

  testWidgets('a busy card becomes its main parts: near copies and small '
      'thin lines give way (seen live: 40 boxes filled a card)', (
    tester,
  ) async {
    await pump(
      tester,
      SizedBox(
        key: rootKey,
        width: 600,
        height: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A panel wrapped twice: three nested near copies.
            Padding(
              padding: const EdgeInsets.all(2),
              child: SizedBox(
                width: 300,
                height: 100,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Container(color: const Color(0xFF000000)),
                ),
              ),
            ),
            // Many thin rows of text-like boxes.
            for (var i = 0; i < 16; i++)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    const SizedBox(width: 90, height: 6),
                    const SizedBox(width: 12),
                    SizedBox(width: 200.0 + i, height: 6),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    final boxes = read(tester);
    expect(boxes.length, lessThanOrEqualTo(ConstructionBoxes.maxBoxes));
    // The panel is there once, not as three nested copies.
    final panels = boxes.where((b) => b.width >= 290 && b.height >= 90);
    expect(panels, hasLength(1), reason: '$boxes');
  });

  testWidgets('the same tree gives the same boxes', (tester) async {
    await pump(
      tester,
      SizedBox(
        key: rootKey,
        width: 300,
        height: 100,
        child: Column(
          children: [
            for (var i = 0; i < 6; i++)
              Padding(
                padding: const EdgeInsets.all(2),
                child: SizedBox(width: 50.0 + i * 10, height: 8),
              ),
          ],
        ),
      ),
    );
    expect(read(tester), read(tester));
    expect(read(tester), isNotEmpty);
  });

  testWidgets('a partly visible widget gets boxes cut to its visible part', (
    tester,
  ) async {
    await pump(
      tester,
      const SizedBox(
        key: rootKey,
        width: 200,
        height: 60,
        child: Row(
          children: [
            SizedBox(width: 40, height: 20),
            SizedBox(width: 60, height: 30),
            SizedBox(width: 100, height: 40),
          ],
        ),
      ),
    );
    final full = rectOf(tester, rootKey);
    // Only the right half shows.
    final visible = Rect.fromLTRB(
      full.left + 100,
      full.top,
      full.right,
      full.bottom,
    );
    final boxes = read(tester, visible);
    expect(boxes, isNotEmpty);
    for (final b in boxes) {
      expect(b.left, greaterThanOrEqualTo(0));
      expect(b.left + b.width, lessThanOrEqualTo(100.01));
    }
    // The 40 px box ends at 40: it is not visible.
    expect(boxes.any((b) => b.width == 40 && b.height == 20), isFalse);
  });

  testWidgets('offstage children are not drawn', (tester) async {
    await pump(
      tester,
      const SizedBox(
        key: rootKey,
        width: 200,
        height: 60,
        child: Row(
          children: [
            Offstage(child: SizedBox(width: 77, height: 33)),
            SizedBox(width: 50, height: 20),
          ],
        ),
      ),
    );
    final boxes = read(tester);
    expect(boxes.any((b) => b.width == 77), isFalse);
    expect(boxes.any((b) => b.width == 50), isTrue);
  });

  testWidgets('the walk is bounded: a deep tree still returns', (tester) async {
    Widget deep(int n) => n == 0
        ? const SizedBox(width: 20, height: 20)
        : Padding(padding: const EdgeInsets.only(left: 1), child: deep(n - 1));
    await pump(
      tester,
      SizedBox(key: rootKey, width: 300, height: 100, child: deep(60)),
    );
    // Past the depth cap: nothing deeper is read, and nothing throws.
    expect(read(tester).length, lessThanOrEqualTo(ConstructionBoxes.maxBoxes));
  });
}
