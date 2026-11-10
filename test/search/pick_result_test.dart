import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/search/element_lookup.dart';
import 'package:pinpoint/src/search/pick_result.dart';
import 'package:pinpoint/src/search/render_search.dart';

/// Milestone 2, build step 2: render object to element, and the pick result.
void main() {
  const rootKey = Key('root');

  Future<Element> pumpFixture(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(key: rootKey, child: child),
      ),
    );
    return tester.element(find.byKey(rootKey));
  }

  PickResult? pickAt(Element root, Offset at, {PickResult? previous}) =>
      PickResult.fromSearch(
        RenderSearch.find(root.renderObject!, at),
        position: at,
        rootElement: root,
        previous: previous,
      );

  group('element lookup', () {
    testWidgets('debug: the owning element comes from debugCreator', (
      tester,
    ) async {
      final root = await pumpFixture(tester, const Center(child: Text('hi')));
      final paragraph = tester.renderObject(find.text('hi'));

      final element = elementFor(paragraph, root: root);
      expect(element, isA<RenderObjectElement>());
      expect(element!.widget, isA<RichText>());
      expect(element.renderObject, same(paragraph));
    });

    testWidgets('other modes: the index maps every render object', (
      tester,
    ) async {
      final root = await pumpFixture(
        tester,
        const Center(
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [Text('a'), SizedBox(width: 10, height: 10)],
            ),
          ),
        ),
      );

      final index = indexRenderObjects(root);
      var checked = 0;
      void check(RenderObject node) {
        final creator = node.debugCreator! as DebugCreator;
        expect(index[node], same(creator.element), reason: '$node');
        checked++;
        node.visitChildren(check);
      }

      root.renderObject!.visitChildren(check);
      expect(checked, greaterThan(4));
    });

    testWidgets('the index walk is capped', (tester) async {
      final root = await pumpFixture(tester, const Center(child: Text('x')));
      expect(indexRenderObjects(root, maxElements: 2).length, lessThan(3));
    });
  });

  group('PickResult', () {
    testWidgets('picking a Text yields its element and exact rect', (
      tester,
    ) async {
      final root = await pumpFixture(tester, const Center(child: Text('hi')));
      final at = tester.getCenter(find.text('hi'));

      final pick = pickAt(root, at)!;
      expect(pick.index, 0);
      expect(pick.position, at);
      // The Text written here is local; the RichText it builds is not.
      expect(pick.element.widget, isA<Text>());
      expect(pick.pickedElement.widget, isA<RichText>());
      expect(pick.sourceUnavailable, isFalse);
      expect(pick.renderObject, same(tester.renderObject(find.text('hi'))));
      expect(pick.globalRect, tester.getRect(find.text('hi')));
    });

    testWidgets('nothing under the point gives null', (tester) async {
      // The root here is a small box, not the whole screen.
      await tester.pumpWidget(
        const Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: rootKey,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );
      final root = tester.element(find.byKey(rootKey));
      expect(pickAt(root, const Offset(5, 5)), isNotNull);
      expect(pickAt(root, const Offset(500, 500)), isNull);
    });

    testWidgets('the same spot again advances, wrapping around', (
      tester,
    ) async {
      final root = await pumpFixture(tester, const Center(child: Text('hi')));
      final at = tester.getCenter(find.text('hi'));

      final first = pickAt(root, at)!;
      final count = first.candidates.length;
      expect(count, greaterThan(1));

      var pick = first;
      for (var i = 1; i < count; i++) {
        pick = pickAt(root, at, previous: pick)!;
        expect(pick.index, i);
        expect(pick.renderObject, same(first.candidates[i].renderObject));
      }
      pick = pickAt(root, at, previous: pick)!;
      expect(pick.index, 0, reason: 'wraps around');
    });

    testWidgets('a different spot starts again at the smallest', (
      tester,
    ) async {
      final root = await pumpFixture(
        tester,
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [Text('top'), Text('bottom')],
          ),
        ),
      );
      final first = pickAt(root, tester.getCenter(find.text('top')))!;
      final advanced = pickAt(
        root,
        tester.getCenter(find.text('top')),
        previous: first,
      )!;
      expect(advanced.index, 1);

      final other = pickAt(
        root,
        tester.getCenter(find.text('bottom')),
        previous: advanced,
      )!;
      expect(other.index, 0);
      expect(
        other.renderObject,
        same(tester.renderObject(find.text('bottom'))),
      );
    });

    testWidgets('refreshed: same instance, moved rect, or null on unmount', (
      tester,
    ) async {
      final left = ValueNotifier<double>(10);
      final show = ValueNotifier<bool>(true);
      addTearDown(left.dispose);
      addTearDown(show.dispose);
      const box = Key('box');
      final root = await pumpFixture(
        tester,
        ListenableBuilder(
          listenable: Listenable.merge([left, show]),
          builder: (context, _) => Stack(
            children: [
              if (show.value)
                Positioned(
                  left: left.value,
                  top: 10,
                  child: const SizedBox(key: box, width: 30, height: 30),
                ),
            ],
          ),
        ),
      );

      final pick = pickAt(root, tester.getCenter(find.byKey(box)))!;
      expect(pick.refreshed(), same(pick), reason: 'nothing moved');

      left.value = 50;
      await tester.pump();
      final moved = pick.refreshed()!;
      expect(moved, isNot(same(pick)));
      expect(moved.globalRect, tester.getRect(find.byKey(box)));
      expect(moved.element, same(pick.element));

      show.value = false;
      await tester.pump();
      expect(moved.refreshed(), isNull);
    });
  });
}
