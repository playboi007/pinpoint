import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/src/search/render_search.dart';

/// Milestone 2, build step 1: the bounds walk against fixture trees, no UI.
void main() {
  const rootKey = Key('root');

  /// Pumps [child] under a RepaintBoundary, the way the wrapper hosts the
  /// app, and returns that boundary's render object: the walk's root.
  Future<RenderObject> pumpFixture(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(key: rootKey, child: child),
      ),
    );
    return tester.renderObject(find.byKey(rootKey));
  }

  List<RenderObject> pick(RenderObject root, Offset at) => RenderSearch.find(
    root,
    at,
  ).candidates.map((c) => c.renderObject).toList();

  RenderObject ro(WidgetTester tester, Key key, {bool skipOffstage = true}) =>
      tester.renderObject(find.byKey(key, skipOffstage: skipOffstage));

  bool isInside(RenderObject node, RenderObject ancestor) {
    for (RenderObject? n = node; n != null; n = n.parent) {
      if (identical(n, ancestor)) return true;
    }
    return false;
  }

  group('acceptance', () {
    testWidgets('a Text is picked with exactly its own bounds', (tester) async {
      final root = await pumpFixture(
        tester,
        const Center(child: Text('hello')),
      );
      final textRect = tester.getRect(find.text('hello'));

      final top = RenderSearch.find(root, textRect.center).candidates.first;
      expect(top.renderObject, isA<RenderParagraph>());
      expect(top.globalRect, textRect);
    });

    testWidgets('a bare SizedBox can be picked', (tester) async {
      const box = Key('box');
      final root = await pumpFixture(
        tester,
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(key: box, width: 40, height: 40),
              Text('below'),
            ],
          ),
        ),
      );

      final at = tester.getCenter(find.byKey(box));
      expect(pick(root, at).first, same(ro(tester, box)));
    });

    testWidgets('the padding area of a Padding can be picked', (tester) async {
      const padding = Key('padding');
      const inner = Key('inner');
      final root = await pumpFixture(
        tester,
        const Center(
          child: Padding(
            key: padding,
            padding: EdgeInsets.all(20),
            child: ColoredBox(
              color: Color(0xFF00FF00),
              child: SizedBox(key: inner, width: 50, height: 50),
            ),
          ),
        ),
      );

      final paddingRect = tester.getRect(find.byKey(padding));
      expect(
        pick(root, paddingRect.topLeft + const Offset(5, 5)).first,
        same(ro(tester, padding)),
        reason: 'a point in the padding, outside the child',
      );
      expect(pick(root, paddingRect.center).first, same(ro(tester, inner)));
    });

    testWidgets('nothing on an opaque route beneath is ever picked', (
      tester,
    ) async {
      const beneath = Key('beneath');
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) =>
              RepaintBoundary(key: rootKey, child: child),
          home: const Scaffold(
            key: beneath,
            body: Center(child: Text('beneath')),
          ),
        ),
      );
      final textRect = tester.getRect(find.text('beneath'));

      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      );
      await tester.pumpAndSettle();
      expect(find.text('beneath'), findsNothing, reason: 'now offstage');

      final root = tester.renderObject(find.byKey(rootKey));
      final beneathRoot = ro(tester, beneath, skipOffstage: false);
      final candidates = pick(root, textRect.center);
      expect(candidates, isNotEmpty, reason: 'the top route is picked');
      for (final candidate in candidates) {
        expect(isInside(candidate, beneathRoot), isFalse);
      }
    });

    testWidgets('a list item scrolled under the app bar is not picked there', (
      tester,
    ) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: rootKey, child: child),
          home: Scaffold(
            appBar: AppBar(title: const Text('bar')),
            body: ListView.builder(
              controller: scroll,
              itemCount: 50,
              itemBuilder: (context, i) =>
                  SizedBox(height: 50, child: Text('item $i')),
            ),
          ),
        ),
      );
      scroll.jumpTo(30);
      await tester.pump();

      final appBar = tester.getRect(find.byType(AppBar));
      final item = tester.getRect(find.text('item 0'));
      expect(item.top, lessThan(appBar.bottom), reason: 'item 0 is under it');
      final at = Offset(item.left + 5, (item.top + appBar.bottom) / 2);
      expect(item.contains(at) && appBar.contains(at), isTrue);

      final root = tester.renderObject(find.byKey(rootKey));
      final viewport = tester.renderObject(find.byType(Viewport));
      final candidates = pick(root, at);
      expect(candidates, isNotEmpty);
      for (final candidate in candidates) {
        expect(isInside(candidate, viewport), isFalse);
      }
    });

    testWidgets('one pick on a 500-item list takes under 8 ms (VM debug)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: rootKey, child: child),
          home: Scaffold(
            appBar: AppBar(title: const Text('Long list')),
            body: ListView.builder(
              itemCount: 500,
              itemBuilder: (context, index) => ListTile(
                leading: CircleAvatar(child: Text('${index + 1}')),
                title: Text('Item ${index + 1}'),
                subtitle: const Text('A subtitle that may wrap.'),
                trailing: const Icon(Icons.more_vert),
              ),
            ),
          ),
        ),
      );
      final root = tester.renderObject(find.byKey(rootKey));
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final random = math.Random(7);
      Offset next() => Offset(
        random.nextDouble() * size.width,
        random.nextDouble() * size.height,
      );

      for (var i = 0; i < 20; i++) {
        RenderSearch.find(root, next()); // warm up the JIT
      }
      final micros = <int>[
        for (var i = 0; i < 200; i++)
          RenderSearch.find(root, next()).elapsed.inMicroseconds,
      ]..sort();
      final p50 = micros[100] / 1000;
      final p95 = micros[190] / 1000;
      debugPrint('pinpoint pick, 200 picks: p50 $p50 ms, p95 $p95 ms');

      // VM debug, not web debug. The browser number is a manual check.
      expect(p95, lessThan(8));
    });
  });

  group('watch out for', () {
    testWidgets('area ties are the norm: the deepest shared-rect widget wins', (
      tester,
    ) async {
      const outer = Key('outer');
      const inner = Key('inner');
      final root = await pumpFixture(
        tester,
        const Center(
          child: SizedBox(
            key: outer,
            width: 100,
            height: 100,
            child: Align(
              child: Padding(
                padding: EdgeInsets.zero,
                child: SizedBox(key: inner, width: 100, height: 100),
              ),
            ),
          ),
        ),
      );

      final at = tester.getCenter(find.byKey(inner));
      final result = RenderSearch.find(root, at);
      final shared = result.candidates
          .where((c) => c.globalRect == tester.getRect(find.byKey(outer)))
          .toList();
      expect(shared.length, greaterThanOrEqualTo(4), reason: 'four wrappers');
      expect(result.candidates.first.renderObject, same(ro(tester, inner)));
    });

    testWidgets('on an area and depth tie the later sibling wins', (
      tester,
    ) async {
      const first = Key('first');
      const second = Key('second');
      final root = await pumpFixture(
        tester,
        const Center(
          child: Stack(
            children: [
              SizedBox(key: first, width: 50, height: 50),
              SizedBox(key: second, width: 50, height: 50),
            ],
          ),
        ),
      );

      final at = tester.getCenter(find.byKey(first));
      final candidates = pick(root, at);
      expect(candidates[0], same(ro(tester, second)), reason: 'paints on top');
      expect(candidates[1], same(ro(tester, first)));
    });

    testWidgets('a rotated widget gets its axis-aligned bounding rect', (
      tester,
    ) async {
      const box = Key('box');
      final root = await pumpFixture(
        tester,
        Center(
          child: Transform.rotate(
            angle: math.pi / 4,
            child: const SizedBox(key: box, width: 100, height: 100),
          ),
        ),
      );
      final boxRo = ro(tester, box);
      final center = tester.getCenter(find.byKey(box));

      final hit = RenderSearch.find(
        root,
        center,
      ).candidates.firstWhere((c) => identical(c.renderObject, boxRo));
      // Larger than the widget: accepted in v1.
      expect(hit.globalRect.width, closeTo(100 * math.sqrt2, 0.01));

      // A corner of the bounding rect lies outside the rotated square. The
      // point test runs in the widget's own space, so it is not picked there.
      final corner = hit.globalRect.topLeft + const Offset(4, 4);
      expect(pick(root, corner), isNot(contains(boxRo)));
    });

    testWidgets('a scaled subtree reports its on-screen rect', (tester) async {
      const box = Key('box');
      final root = await pumpFixture(
        tester,
        Center(
          child: Transform.scale(
            scale: 2,
            child: const SizedBox(key: box, width: 50, height: 50),
          ),
        ),
      );

      final rect = tester.getRect(find.byKey(box));
      expect(rect.width, 100);
      final boxRo = ro(tester, box);
      final hit = RenderSearch.find(
        root,
        rect.center,
      ).candidates.firstWhere((c) => identical(c.renderObject, boxRo));
      expect(hit.globalRect, rect);

      // The Transform keeps its own 50 x 50 layout box, so it wins on area at
      // the center. Outside that box only the scaled child is there.
      final outside = rect.topLeft + const Offset(5, 5);
      expect(pick(root, outside).first, same(boxRo));
    });

    testWidgets('a singular transform (scale 0) is skipped without an error', (
      tester,
    ) async {
      const box = Key('box');
      final root = await pumpFixture(
        tester,
        Center(
          child: Transform.scale(
            scale: 0,
            child: const SizedBox(key: box, width: 50, height: 50),
          ),
        ),
      );

      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final result = RenderSearch.find(root, size.center(Offset.zero));
      expect(tester.takeException(), isNull);
      expect(
        result.candidates.map((c) => c.renderObject),
        isNot(contains(ro(tester, box))),
      );
      for (final c in result.candidates) {
        expect(c.globalRect.isFinite, isTrue);
      }
    });

    testWidgets('a render object that throws does not kill the pick', (
      tester,
    ) async {
      const good = Key('good');
      final root = await pumpFixture(
        tester,
        const Center(
          child: SizedBox(
            width: 80,
            height: 80,
            child: Stack(
              fit: StackFit.expand,
              children: [
                SizedBox(key: good),
                _Throwing(),
              ],
            ),
          ),
        ),
      );

      final result = RenderSearch.find(
        root,
        tester.getCenter(find.byKey(good)),
      );
      expect(result.errors, greaterThan(0));
      expect(
        result.candidates.map((c) => c.renderObject),
        contains(ro(tester, good)),
      );
    });

    testWidgets('the walk stops at the node cap and says so', (tester) async {
      final root = await pumpFixture(
        tester,
        const Center(child: Text('capped')),
      );
      final at = tester.getCenter(find.text('capped'));

      final capped = RenderSearch.find(root, at, maxNodes: 2);
      expect(capped.truncated, isTrue);
      expect(capped.visited, 2);

      final full = RenderSearch.find(root, at);
      expect(full.truncated, isFalse);
      expect(full.visited, greaterThan(2));
    });
  });

  group('fixtures', () {
    testWidgets('a child that overflows its parent is picked outside it', (
      tester,
    ) async {
      const parent = Key('parent');
      const child = Key('child');
      final root = await pumpFixture(
        tester,
        const Center(
          child: SizedBox(
            key: parent,
            width: 50,
            height: 50,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 60,
                  top: 0,
                  child: SizedBox(key: child, width: 20, height: 20),
                ),
              ],
            ),
          ),
        ),
      );

      final at = tester.getCenter(find.byKey(child));
      expect(tester.getRect(find.byKey(parent)).contains(at), isFalse);
      expect(pick(root, at).first, same(ro(tester, child)));
    });

    testWidgets('a child translated out of its parent is picked', (
      tester,
    ) async {
      const child = Key('child');
      final root = await pumpFixture(
        tester,
        Center(
          child: SizedBox(
            width: 50,
            height: 50,
            child: Transform.translate(
              offset: const Offset(100, 0),
              child: const SizedBox(key: child, width: 50, height: 50),
            ),
          ),
        ),
      );

      final at = tester.getCenter(find.byKey(child));
      expect(pick(root, at).first, same(ro(tester, child)));
    });

    testWidgets('a clipped-away part of a child is not picked', (tester) async {
      const child = Key('child');
      final root = await pumpFixture(
        tester,
        const Center(
          child: SizedBox(
            width: 50,
            height: 50,
            child: ClipRect(
              child: OverflowBox(
                maxWidth: 200,
                maxHeight: 200,
                child: SizedBox(key: child, width: 200, height: 200),
              ),
            ),
          ),
        ),
      );

      final rect = tester.getRect(find.byKey(child));
      final childRo = ro(tester, child);
      expect(pick(root, rect.center), contains(childRo), reason: 'inside clip');
      expect(
        pick(root, rect.topLeft + const Offset(10, 10)),
        isNot(contains(childRo)),
        reason: 'outside the 50x50 clip',
      );
    });

    testWidgets('a Stack with overlapping children lists both', (tester) async {
      const big = Key('big');
      const small = Key('small');
      final root = await pumpFixture(
        tester,
        const Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: Stack(
              children: [
                Positioned.fill(child: SizedBox(key: big)),
                Positioned(
                  left: 10,
                  top: 10,
                  child: SizedBox(key: small, width: 30, height: 30),
                ),
              ],
            ),
          ),
        ),
      );

      final candidates = pick(root, tester.getCenter(find.byKey(small)));
      expect(candidates.first, same(ro(tester, small)));
      expect(candidates, contains(ro(tester, big)));
    });

    testWidgets('an Offstage subtree is never picked', (tester) async {
      const shown = Key('shown');
      const hidden = Key('hidden');
      final root = await pumpFixture(
        tester,
        const Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: Stack(
              children: [
                SizedBox(key: shown, width: 100, height: 100),
                Offstage(child: SizedBox(key: hidden, width: 100, height: 100)),
              ],
            ),
          ),
        ),
      );

      final candidates = pick(root, tester.getCenter(find.byKey(shown)));
      expect(candidates.first, same(ro(tester, shown)));
      expect(
        candidates,
        isNot(contains(ro(tester, hidden, skipOffstage: false))),
      );
    });

    testWidgets('an IndexedStack yields only its shown child', (tester) async {
      const a = Key('a');
      const b = Key('b');
      final root = await pumpFixture(
        tester,
        const Center(
          child: IndexedStack(
            index: 1,
            children: [
              SizedBox(key: a, width: 100, height: 100),
              SizedBox(key: b, width: 100, height: 100),
            ],
          ),
        ),
      );

      final candidates = pick(
        root,
        tester.getCenter(find.byKey(b, skipOffstage: false)),
      );
      expect(candidates.first, same(ro(tester, b, skipOffstage: false)));
      expect(candidates, isNot(contains(ro(tester, a, skipOffstage: false))));
    });

    testWidgets('a nested scroll view clips its scrolled-out items', (
      tester,
    ) async {
      final inner = ScrollController();
      addTearDown(inner.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              RepaintBoundary(key: rootKey, child: child),
          home: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 100),
                child: SizedBox(
                  height: 100,
                  child: ListView.builder(
                    controller: inner,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (context, i) =>
                        SizedBox(width: 80, child: Text('h$i')),
                  ),
                ),
              ),
              for (var i = 0; i < 20; i++)
                SizedBox(height: 60, child: Text('v$i')),
            ],
          ),
        ),
      );
      inner.jumpTo(60);
      await tester.pump();

      final root = tester.renderObject(find.byKey(rootKey));
      final h0 = tester.renderObject(find.text('h0'));
      final h0Rect = tester.getRect(find.text('h0'));
      expect(h0Rect.left, lessThan(100), reason: 'scrolled past the left');

      expect(
        pick(root, Offset(h0Rect.left + 2, h0Rect.center.dy)),
        isNot(contains(h0)),
      );
      expect(pick(root, Offset(105, h0Rect.center.dy)), contains(h0));
      expect(
        pick(root, tester.getCenter(find.text('v1'))).first,
        same(tester.renderObject(find.text('v1'))),
      );
    });

    testWidgets('a sliver list is walked: slivers and their items', (
      tester,
    ) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: rootKey,
            child: CustomScrollView(
              slivers: [
                SliverList.builder(
                  itemCount: 30,
                  itemBuilder: (context, i) =>
                      SizedBox(height: 40, child: Text('s$i')),
                ),
              ],
            ),
          ),
        ),
      );
      final root = tester.renderObject(find.byKey(rootKey));
      final at = tester.getCenter(find.text('s2'));

      final result = RenderSearch.find(root, at);
      expect(
        result.candidates.first.renderObject,
        same(tester.renderObject(find.text('s2'))),
      );
      final sliver = result.candidates.firstWhere(
        (c) => c.renderObject is RenderSliverList,
      );
      expect(sliver.globalRect.isFinite, isTrue);
      expect(sliver.globalRect.contains(at), isTrue);
    });
  });

  group('globalRectOf', () {
    testWidgets('matches the rect debugPaintSize draws', (tester) async {
      const box = Key('box');
      await pumpFixture(
        tester,
        const Padding(
          padding: EdgeInsets.only(left: 13, top: 7),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(key: box, width: 31, height: 17),
          ),
        ),
      );
      final box0 = ro(tester, box) as RenderBox;
      expect(
        RenderSearch.globalRectOf(box0),
        box0.localToGlobal(Offset.zero) & box0.size,
      );
    });

    testWidgets('is null for a detached render object', (tester) async {
      const box = Key('box');
      await pumpFixture(tester, const SizedBox(key: box));
      final detached = ro(tester, box);
      await pumpFixture(tester, const SizedBox());
      expect(detached.attached, isFalse);
      expect(RenderSearch.globalRectOf(detached), isNull);
    });
  });
}

/// A leaf whose paint bounds throw, like a render object read before layout.
class _Throwing extends LeafRenderObjectWidget {
  const _Throwing();

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderThrowing();
}

class _RenderThrowing extends RenderBox {
  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  Rect get paintBounds => throw StateError('not ready');
}
