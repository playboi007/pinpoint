import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinpoint/pinpoint.dart';

/// Milestone 2, build step 4: wheel events over the trap scroll the app.
void main() {
  late PinPointController controller;

  setUp(() => controller = PinPointController());
  tearDown(() => controller.dispose());

  Widget host(Widget home) => MaterialApp(
    builder: (context, child) =>
        PinPointWrapper(controller: controller, child: child),
    home: Scaffold(body: home),
  );

  Future<void> wheel(WidgetTester tester, Offset at, Offset delta) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(at);
    await tester.sendEventToBinding(pointer.scroll(delta));
    await tester.pump();
  }

  Future<void> startPicking(WidgetTester tester) async {
    controller.startPicking();
    await tester.pump();
  }

  testWidgets('the wheel scrolls the list under the cursor while picking', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var tapped = false;
    await tester.pumpWidget(
      host(
        ListView.builder(
          controller: scroll,
          itemCount: 100,
          itemBuilder: (context, i) => SizedBox(
            height: 50,
            child: GestureDetector(
              onTap: () => tapped = true,
              child: Text('item $i'),
            ),
          ),
        ),
      ),
    );
    await startPicking(tester);

    await wheel(tester, const Offset(100, 200), const Offset(0, 120));
    expect(scroll.offset, 120);
    expect(tapped, isFalse);
    expect(controller.mode, PinPointMode.picking);
  });

  testWidgets('the axis follows the larger delta in nested lists', (
    tester,
  ) async {
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await tester.pumpWidget(
      host(
        ListView(
          controller: outer,
          children: [
            SizedBox(
              height: 100,
              child: ListView.builder(
                controller: inner,
                scrollDirection: Axis.horizontal,
                itemCount: 50,
                itemBuilder: (context, i) =>
                    SizedBox(width: 80, child: Text('h$i')),
              ),
            ),
            for (var i = 0; i < 50; i++)
              SizedBox(height: 50, child: Text('v$i')),
          ],
        ),
      ),
    );
    await startPicking(tester);
    final overInner = tester.getCenter(find.text('h1'));

    await wheel(tester, overInner, const Offset(5, 30));
    expect(outer.offset, 30, reason: 'mostly vertical');
    expect(inner.offset, 0);

    final stillOverInner = tester.getCenter(find.text('h1'));
    await wheel(tester, stillOverInner, const Offset(70, 5));
    expect(inner.offset, 70, reason: 'mostly horizontal');
    expect(outer.offset, 30);
  });

  testWidgets('an inner list at its end passes the wheel to the outer one', (
    tester,
  ) async {
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    await tester.pumpWidget(
      host(
        ListView(
          controller: outer,
          children: [
            SizedBox(
              height: 200,
              child: ListView.builder(
                controller: inner,
                itemCount: 10,
                itemBuilder: (context, i) =>
                    SizedBox(height: 50, child: Text('in$i')),
              ),
            ),
            for (var i = 0; i < 50; i++)
              SizedBox(height: 50, child: Text('out$i')),
          ],
        ),
      ),
    );
    inner.jumpTo(inner.position.maxScrollExtent);
    await tester.pump();
    await startPicking(tester);

    await wheel(tester, const Offset(100, 100), const Offset(0, 40));
    expect(outer.offset, 40);
  });

  testWidgets('a reversed list scrolls as it does without Pinpoint', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ListView.builder(
          controller: scroll,
          reverse: true,
          itemCount: 100,
          itemBuilder: (context, i) => SizedBox(height: 50, child: Text('r$i')),
        ),
      ),
    );
    scroll.jumpTo(500);
    await tester.pump();

    await wheel(tester, const Offset(100, 200), const Offset(0, 80));
    final byApp = scroll.offset;
    expect(byApp, isNot(500));

    scroll.jumpTo(500);
    await tester.pump();
    await startPicking(tester);
    await wheel(tester, const Offset(100, 200), const Offset(0, 80));
    expect(scroll.offset, byApp);
  });

  testWidgets('the hover outline moves to what is now under the cursor', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        ListView.builder(
          itemCount: 100,
          itemBuilder: (context, i) =>
              SizedBox(height: 50, child: Text('item $i')),
        ),
      ),
    );
    await startPicking(tester);
    final at = tester.getCenter(find.text('item 2'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: at);
    await mouse.moveTo(at);
    await tester.pump();
    expect(
      controller.hovered.value!.renderObject,
      same(tester.renderObject(find.text('item 2'))),
    );

    await wheel(tester, at, const Offset(0, 100));
    await tester.pump();
    expect(
      controller.hovered.value!.renderObject,
      same(tester.renderObject(find.text('item 4'))),
    );
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a wheel with nothing scrollable underneath is ignored', (
    tester,
  ) async {
    await tester.pumpWidget(host(const Center(child: Text('static'))));
    await startPicking(tester);
    await wheel(
      tester,
      tester.getCenter(find.text('static')),
      const Offset(0, 50),
    );
    expect(tester.takeException(), isNull);
  });
}
